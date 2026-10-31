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

    // ---------- inspection ----------
    /// The point being inspected, or nil when the card is closed. Held
    /// separately from the summary so the card can open immediately with
    /// coordinates and fill in as providers answer.
    private(set) var inspectedPoint: Coordinate?
    private(set) var inspection: LocationSummary?
    private(set) var isInspecting = false

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
