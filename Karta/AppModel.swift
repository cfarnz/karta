import Foundation
import Observation
import RouteBuilderCore

/// App state and the wiring between the UI and the core.
///
/// The route logic lives in `RouteBuilderCore` and knows nothing about
/// SwiftUI; this is the seam. Mutations happen synchronously on the main actor
/// so the map and the stats can never show two different routes, while the
/// network work is awaited off to the services.
@Observable
@MainActor
final class AppModel {
    // ---------- route ----------
    /// Written only through `route` below, so the profile can never fall out
    /// of step with the track it was built from.
    private var storedRoute = RouteState()

    /// Mutating this — including in place, as `route.waypoints.append` does —
    /// goes through the setter and rebuilds the profile. Funnelling every
    /// write through one place beats recomputing at the end of each editing
    /// method, which is a step that is easy to forget to add to the next one.
    private(set) var route: RouteState {
        get { storedRoute }
        set {
            storedRoute = newValue
            // Cached rather than computed on read: a long route is a couple
            // of thousand points, and SwiftUI reads this on every frame of a
            // map pan.
            profile = ElevationProfile(track: newValue.track)
            // A cursor placed by a scrub refers to a point on the old track.
            cursor = nil
        }
    }

    private var undoStack: [RouteState] = []

    /// Distance versus elevation along the current track.
    private(set) var profile = ElevationProfile.empty

    /// The sample currently being scrubbed on the elevation profile. The
    /// chart reads it for its readout and the map for its marker, so it lives
    /// here rather than inside the chart — two views showing one cursor.
    /// Nil when nothing is being scrubbed.
    var cursor: ProfilePoint?
    /// Outstanding leg rebuilds. A count rather than a flag because dragging a
    /// middle waypoint rebuilds two legs at once.
    private(set) var pendingLegs = 0

    var canUndo: Bool { !undoStack.isEmpty }
    var isBusy: Bool { pendingLegs > 0 }
    var stats: RouteStats { route.stats }
    var track: [Coordinate] { route.track }

    // ---------- map ----------
    var basemap: Basemap = .openTopo
    /// Shaded relief from the Terrarium DEM. Named for what it is: MapLibre
    /// Native has no 3D terrain, so there is no tilt to enable.
    var hillshadeEnabled = false
    /// Nil means no terrain overlay.
    var terrainOverlay: TerrainOverlay?

    // ---------- discover ----------
    var discoverSettings = DiscoverSettings()
    private(set) var discoverState = DiscoverState.idle
    private(set) var candidates: [Candidate] = []
    /// The candidate previewed on the map. On the web this was whatever the
    /// pointer was hovering; a touch screen has no hover, so it is the
    /// selected row and it stays until another is picked.
    var previewedCandidate: Candidate?
    /// Set after a search so the map can frame what it found, then cleared so
    /// it does not re-frame on unrelated redraws.
    var pendingFit: [Coordinate]?

    private let location = LocationProvider()
    private let stream = LocationStreamProvider()
    private let tracks = TrackStore()

    // ---------- inspection ----------
    /// The point being inspected, or nil when the card is closed. Held
    /// separately from the summary so the card can open immediately with
    /// coordinates and fill in as providers answer.
    private(set) var inspectedPoint: Coordinate?
    private(set) var inspection: LocationSummary?
    private(set) var isInspecting = false

    // ---------- recording ----------
    /// The session. A value type inside `@Observable`, so mutating it through
    /// these methods publishes to the UI the same as any other property.
    private(set) var recorder = TrackRecorder()
    /// Offered when a manual pause ends having moved. Nil the rest of the
    /// time, and the UI's only cue to ask.
    var pendingRecovery: RecoveredStretch? { recorder.pendingRecovery }
    /// Filling elevations from the DEM after a recording stops.
    private(set) var isFinishingRecording = false
    private var fixes: Task<Void, Never>?
    /// Recordings on disk, newest first.
    private(set) var savedTracks: [TrackSummary] = []
    /// A recording the app did not finish, found at launch. The user decides
    /// what happens to it before anything else touches the journal.
    private(set) var interrupted: Track?
    /// How much of the track has reached the journal. Appending the delta
    /// after every event covers splices and recoveries too, which mirroring
    /// each individual decision would not.
    private var journaledPoints = 0
    private var journaledGaps = 0
    private var hasFramedRecording = false

    var isRecording: Bool { recorder.state.wantsLocation }
    var recordingStats: TrackStats { recorder.track.stats }
    /// A saved recording opened from the list, or nil.
    private(set) var viewedTrack: Track?
    /// Which one, so deleting the open recording can close it.
    private(set) var viewedTrackID: UUID?
    /// Built once when a recording is opened, for the same reason the route's
    /// profile is cached: SwiftUI reads it on every frame of a map pan.
    private(set) var viewedProfile = ElevationProfile.empty

    /// What the map draws. A live recording wins — the list is unreachable
    /// while one is running, so the two can never compete for the line.
    var recordedSpans: [TrackSpan] {
        isRecording ? recorder.track.spans : viewedTrack?.spans ?? []
    }

    // ---------- provenance ----------
    private(set) var provenance: [ProvenanceRecord] = []

    // ---------- services ----------
    private let cache: ProviderCache
    private let elevation: ElevationService
    private let router: Router
    let discover: DiscoverService
    private let summaries: LocationSummaryService

    init() {
        let http = URLSessionFetcher()
        let cache = ProviderCache()
        let elevation = ElevationService(http: http, cache: cache)
        self.cache = cache
        self.elevation = elevation
        self.router = Router(http: http, elevation: elevation)
        self.discover = DiscoverService(http: http, cache: cache, elevation: elevation)
        self.summaries = LocationSummaryService(http: http, cache: cache, elevation: elevation)
    }

    // ---------- editing ----------

    private static let undoLimit = 50

    /// Value semantics make a snapshot a copy. The web app serialised the
    /// whole route to JSON here.
    private func snapshot() {
        undoStack.append(route)
        if undoStack.count > Self.undoLimit { undoStack.removeFirst() }
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        route = previous
    }

    func clear() {
        guard !route.isEmpty else { return }
        snapshot()
        route = RouteState()
    }

    func addWaypoint(_ coordinate: Coordinate) async {
        // Recording takes the map. A stray tap landing in a route somebody
        // forgot was open is a worse outcome than not being able to plan
        // mid-hike, and the long-press inspection still works.
        guard !isRecording else { return }
        snapshot()
        await addWaypointWithoutSnapshot(coordinate)
    }

    /// Loading a discovered route adds a dozen vias in a row, and each one
    /// pushing its own snapshot would bury the previous route under a dozen
    /// taps of undo.
    private func addWaypointWithoutSnapshot(_ coordinate: Coordinate) async {
        route.waypoints.append(coordinate)
        guard route.waypoints.count > 1 else { return }

        let index = route.waypoints.count - 2
        route.legs.append(nil)
        await rebuildLeg(at: index)
    }

    func moveWaypoint(at index: Int, to coordinate: Coordinate) async {
        guard route.waypoints.indices.contains(index) else { return }
        snapshot()
        route.waypoints[index] = coordinate

        // A middle waypoint touches the leg on each side; the ends touch one.
        var indices: [Int] = []
        if index > 0 { indices.append(index - 1) }
        if index < route.waypoints.count - 1 { indices.append(index) }

        // At most two, and they overlap: both suspend on their own network
        // round trip, so a middle-waypoint drag costs one leg's latency
        // rather than two.
        if indices.count == 2 {
            async let first: Void = rebuildLeg(at: indices[0])
            async let second: Void = rebuildLeg(at: indices[1])
            _ = await (first, second)
        } else if let only = indices.first {
            await rebuildLeg(at: only)
        }
    }

    func deleteWaypoint(at index: Int) async {
        guard route.waypoints.indices.contains(index) else { return }
        snapshot()
        route.waypoints.remove(at: index)

        if index == 0 {
            if !route.legs.isEmpty { route.legs.removeFirst() }
        } else if index == route.legs.count {
            if !route.legs.isEmpty { route.legs.removeLast() }
        } else {
            // The two legs that met at the removed point become one.
            route.legs.replaceSubrange((index - 1)...index, with: [nil])
            await rebuildLeg(at: index - 1)
        }
    }

    private func rebuildLeg(at index: Int) async {
        guard route.waypoints.indices.contains(index),
              route.waypoints.indices.contains(index + 1)
        else { return }

        let from = route.waypoints[index]
        let to = route.waypoints[index + 1]

        pendingLegs += 1
        defer { pendingLegs -= 1 }

        let routed = await router.routeLeg(from: from, to: to)

        // The route can have changed while this was in flight — a fast drag
        // fires several rebuilds and they do not land in order. Only apply the
        // result if the endpoints it was computed for are still there.
        guard route.waypoints.indices.contains(index),
              route.waypoints.indices.contains(index + 1),
              route.waypoints[index] == from,
              route.waypoints[index + 1] == to,
              route.legs.indices.contains(index)
        else { return }

        route.legs[index] = routed.leg
        note(routed.provenance)
    }

    // ---------- recording ----------

    func startRecording() async {
        guard !isRecording else { return }
        closeTrack()
        recorder = TrackRecorder()
        recorder.start()
        await beginRecording(named: defaultRecordingName)
    }

    /// Picks up the recording the app was killed during.
    func continueInterrupted() async {
        guard let interrupted else { return }
        recorder.resume(from: interrupted)
        self.interrupted = nil
        // The journal is rewritten from the recovered track rather than
        // appended to: the old one may end mid-line, and a fresh file with
        // everything replayed into it is simpler than reasoning about where
        // the damage stopped.
        await beginRecording(named: recorder.track.name, replaying: recorder.track)
    }

    /// Saves it as it stands, gap and all.
    func saveInterrupted() async {
        guard let interrupted else { return }
        self.interrupted = nil
        await finish(interrupted)
    }

    func discardInterrupted() async {
        interrupted = nil
        await tracks.discardJournal()
    }

    private var defaultRecordingName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM, HH:mm"
        return "Hike \(formatter.string(from: Date()))"
    }

    private func beginRecording(named name: String, replaying track: Track? = nil) async {
        await beginJournaling(named: name, replaying: track)

        // One task for the life of the recording. The stream stays up through
        // a pause on purpose: that is what makes a forgotten pause
        // recoverable rather than a hole to be estimated.
        let fixes = stream.start()
        self.fixes = Task { [weak self] in
            for await fix in fixes {
                guard let self else { return }
                let event = recorder.consider(fix)
                frameRecordingIfFirst(event)
                // Every accepted fix reaches the disk before the next one
                // arrives. A hike held in memory until the user taps stop is
                // a hike that iOS can take away four hours in.
                await journalDelta()
            }
        }
    }

    private func beginJournaling(named name: String, replaying track: Track? = nil) async {
        hasFramedRecording = false
        journaledPoints = 0
        journaledGaps = 0
        await tracks.beginJournal(name: name, at: Date())
        if track != nil { await journalDelta() }
    }

    /// Appends whatever the track has gained since the last call.
    ///
    /// Walks the track rather than reacting to each event, so a recovered
    /// stretch spliced in all at once lands in the journal the same as a fix
    /// arriving one at a time.
    private func journalDelta() async {
        var seen = 0
        for (index, segment) in recorder.track.segments.enumerated() {
            if index > 0, journaledGaps < index,
               recorder.track.gaps.indices.contains(index - 1) {
                await tracks.appendBreak(cause: recorder.track.gaps[index - 1].cause)
                journaledGaps = index
            }

            let already = max(0, journaledPoints - seen)
            if already < segment.points.count {
                for point in segment.points[already...] {
                    await tracks.appendPoint(point)
                }
                journaledPoints += segment.points.count - already
            }
            seen += segment.points.count
        }
    }

    /// Moves the camera to the recording once, on its first accepted fix.
    ///
    /// Once, not continuously: a recording that drags the map on every fix
    /// cannot be panned away from to look at the ridge ahead, which is a
    /// thing people do while a recording runs. The first fix is different —
    /// before it there is nothing on screen to look at, and the map is
    /// wherever it was left, possibly a different range entirely.
    private func frameRecordingIfFirst(_ event: RecorderEvent) {
        guard case .recorded = event,
              hasFramedRecording == false,
              let point = recorder.track.firstPoint
        else { return }
        hasFramedRecording = true
        // A pair, because framing takes bounds and one point has none. A few
        // hundred metres either side puts the start in a readable context
        // rather than at maximum zoom.
        pendingFit = [
            point.coordinate.offset(bearingDegrees: 225, distanceM: 400),
            point.coordinate.offset(bearingDegrees: 45, distanceM: 400),
        ]
    }

    func pauseRecording() {
        recorder.pause()
    }

    /// Resuming is where a recovery gets offered, so the answer lands in
    /// `pendingRecovery` for the UI to ask about rather than being applied.
    func resumeRecording() {
        _ = recorder.resume()
    }

    func acceptRecovery() {
        recorder.acceptRecovery()
    }

    func discardRecovery() {
        recorder.discardRecovery()
    }

    func acceptRecoveryAndJournal() async {
        recorder.acceptRecovery()
        // The buffered points were never journaled — they were not on the
        // track. Accepting them makes them real, so they go to disk now
        // rather than waiting for the next fix.
        await journalDelta()
    }

    /// Ends the recording and fills in elevations from the DEM.
    ///
    /// GPS altitude is far noisier than GPS position, and summing it produces
    /// a gain figure that is mostly noise — the vertical version of the
    /// problem the track filter solves horizontally. Sampling the DEM along
    /// the recorded line instead makes a recorded hike's gain comparable with
    /// a planned route's, and the sources panel says where it came from.
    func stopRecording() async {
        guard isRecording else { return }
        fixes?.cancel()
        fixes = nil
        stream.stop()
        recorder.stop()

        guard !recorder.track.isEmpty else {
            // Started and stopped without a fix. Nothing to keep, and a
            // journal left behind would be offered back on the next launch.
            await tracks.discardJournal()
            return
        }
        let finished = await finish(recorder.track)
        recorder.replaceTrack(with: finished)
    }

    /// Fills elevations, writes the track, drops the journal.
    @discardableResult
    private func finish(_ track: Track) async -> Track {
        isFinishingRecording = true
        defer { isFinishingRecording = false }

        var track = track
        for index in track.segments.indices {
            let flat = track.segments[index].coordinates.map(\.flat)
            guard !flat.isEmpty else { continue }
            let sampled = await elevation.elevations(for: flat)
            guard sampled.values.count == flat.count else { continue }
            for (point, value) in zip(track.segments[index].points.indices, sampled.values) {
                track.segments[index].points[point].coordinate.elevation = value
            }
            note(sampled.provenance)
        }

        // Saved after the fill, so what is on disk is what the user saw.
        await tracks.save(track)
        await refreshSavedTracks()
        return track
    }

    // ---------- saved recordings ----------

    func refreshSavedTracks() async {
        savedTracks = await tracks.list()
    }

    /// Looks for a recording the app was killed during. Called once at launch.
    func findInterruptedRecording() async {
        guard await tracks.hasUnfinishedRecording else { return }
        interrupted = await tracks.recoverJournal()
        // A journal with no points in it has nothing to offer back, and
        // leaving it would ask the same empty question every launch.
        if interrupted == nil { await tracks.discardJournal() }
    }

    func deleteTrack(_ id: UUID) async {
        // Closing first, or the map would keep drawing a recording that no
        // longer exists and the bar would offer to export it.
        if viewedTrackID == id { closeTrack() }
        await tracks.delete(id)
        await refreshSavedTracks()
    }

    func loadTrack(_ id: UUID) async -> Track? {
        await tracks.load(id)
    }

    /// Opens a saved recording onto the map.
    ///
    /// Read-only: a recording is evidence, and the app has no story for
    /// editing one. The route underneath is left alone rather than replaced,
    /// so closing the recording puts the user back where they were.
    func openTrack(_ id: UUID) async {
        guard let track = await tracks.load(id) else { return }
        viewedTrack = track
        viewedTrackID = id
        cursor = nil

        // The profile follows the drawn line, bridges included, so the chart
        // and the map agree about where a given distance falls. An unbridged
        // gap is a jump in both, which is the honest reading of one.
        let drawn = track.spans.flatMap(\.coordinates)
        viewedProfile = ElevationProfile(track: drawn)
        pendingFit = drawn.count >= 2 ? drawn : nil
    }

    func closeTrack() {
        viewedTrack = nil
        viewedTrackID = nil
        viewedProfile = .empty
        cursor = nil
    }

    #if DEBUG
    /// Drives the recorder with synthetic fixes, no CoreLocation involved.
    ///
    /// Not a convenience: `simctl privacy grant location` does not take on the
    /// iOS 27 simulator, so the permission alert blocks every headless run and
    /// a real recording cannot be exercised by a script at all. Feeding the
    /// recorder directly is the only way to see the whole chain — filter,
    /// auto-pause, recovery, spans, stats — without a finger on the screen.
    ///
    /// Each fix is judged against its own timestamp rather than the wall
    /// clock, or a simulated twenty-minute walk would be thrown out as stale
    /// before it reached the track.
    func simulateRecording(forgottenPause: Bool) async {
        recorder = TrackRecorder()
        recorder.start()
        await beginJournaling(named: "Simulated hike")

        var coordinate = Coordinate(longitude: -106.4752, latitude: 39.1875)  // Mt Massive
        var elapsed = 0.0
        let base = Date()

        func feed(_ next: Coordinate, after seconds: Double) async {
            elapsed += seconds
            coordinate = next
            let stamp = base.addingTimeInterval(elapsed)
            let event = recorder.consider(
                LocationFix(coordinate: next, horizontalAccuracyM: 6, timestamp: stamp),
                now: stamp.addingTimeInterval(1)
            )
            frameRecordingIfFirst(event)
            await journalDelta()
        }

        // Walking.
        for _ in 0..<12 {
            await feed(coordinate.offset(bearingDegrees: 285, distanceM: 45), after: 30)
        }

        if forgottenPause {
            // Pressed pause at a creek, then kept walking: the case that
            // leaves a hole in most trackers and a recovery prompt here.
            recorder.pause()
            for _ in 0..<7 {
                await feed(coordinate.offset(bearingDegrees: 285, distanceM: 48), after: 60)
            }
            _ = recorder.resume()
        } else {
            // Stood still long enough to trip the automatic pause, then
            // walked on, which splices itself back without asking.
            for _ in 0..<6 { await feed(coordinate, after: 30) }
            for _ in 0..<6 {
                await feed(coordinate.offset(bearingDegrees: 285, distanceM: 50), after: 30)
            }
        }
    }
    #endif

    // ---------- provenance ----------

    func note(_ record: ProvenanceRecord) {
        provenance.removeAll { $0.dataset == record.dataset }
        provenance.append(record)
        provenance.sort { $0.at > $1.at }
    }

    /// Drives the sources control's active state, so a stale source is
    /// visible without opening the panel.
    var hasStaleSource: Bool { provenance.contains { $0.isStale } }

    func note(_ records: [ProvenanceRecord]) {
        for record in records { note(record) }
    }

    // ---------- discover ----------

    /// Where a Discover search has got to. One value rather than a bag of
    /// flags and strings, so the sheet cannot render "searching" and a result
    /// count at the same time.
    enum DiscoverState: Equatable {
        case idle
        case locating
        /// Completed and total candidate jobs, for a real bar rather than a
        /// spinner over a search that can take half a minute.
        case searching(done: Int, total: Int)
        case finished(count: Int, usedMapCenter: Bool)
        case failed(String)
        case loading
        case loaded(String)
    }

    var isDiscovering: Bool {
        switch discoverState {
        case .locating, .searching, .loading: true
        default: false
        }
    }

    /// `mapCenter` is the fallback when there is no location fix, matching
    /// the web app: a search from the middle of the screen beats no search.
    func runDiscover(mapCenter: Coordinate) async {
        guard !isDiscovering else { return }
        candidates = []
        previewedCandidate = nil
        discoverState = .locating

        let fix = await location.currentLocation()
        let center = fix ?? mapCenter
        let usedMapCenter = fix == nil

        discoverState = .searching(done: 0, total: 0)
        let result = await discover.discover(discoverSettings.options(center: center)) {
            done, total in
            // The service reports from inside a task group, off the main
            // actor, so the hop back is required rather than incidental.
            Task { @MainActor [weak self] in
                guard let self, case .searching = discoverState else { return }
                discoverState = .searching(done: done, total: total)
            }
        }

        note(result.provenance)
        candidates = result.candidates
        // Framing every candidate at once is what makes the result list
        // legible — otherwise the map is still wherever it was.
        pendingFit = result.candidates.isEmpty
            ? nil : result.candidates.flatMap(\.coordinates)
        discoverState = .finished(count: result.candidates.count,
                                  usedMapCenter: usedMapCenter)
    }

    /// Replaces the route with a candidate's via points.
    ///
    /// The vias are re-routed one leg at a time rather than the candidate's
    /// finished track being dropped in whole. That costs a few round trips,
    /// and buys a route the user can actually drag — which is the point of
    /// loading it into the builder instead of just looking at it.
    func load(_ candidate: Candidate) async {
        guard !isDiscovering else { return }
        discoverState = .loading
        previewedCandidate = nil

        snapshot()
        route = RouteState()
        for via in candidate.vias {
            await addWaypointWithoutSnapshot(via)
        }

        discoverState = .loaded(
            "\(candidate.name) \(Int(candidate.distanceMiles.rounded())) mi loop")
    }

    func clearDiscoverResults() {
        candidates = []
        previewedCandidate = nil
        discoverState = .idle
    }

    // ---------- inspection ----------

    /// Long-press anywhere to read the ground there.
    ///
    /// The web app made this a mode: arm "Inspect a point", then click. A
    /// long press needs no mode and cannot be left switched on by accident,
    /// which matters when the plain tap adds a waypoint.
    func inspect(at point: Coordinate) async {
        inspectedPoint = point
        inspection = nil
        isInspecting = true
        defer { isInspecting = false }

        let result = await summaries.summary(for: point)

        // A second long press while the first was in flight wins; dropping
        // the stale answer stops the card flickering back to the old point.
        guard inspectedPoint == point else { return }
        inspection = result.summary
        note(result.provenance)
    }

    func closeInspection() {
        inspectedPoint = nil
        inspection = nil
    }

    // ---------- housekeeping ----------

    func flushCaches() async {
        await cache.flushPoints()
        await cache.enforceBudget()
    }
}
