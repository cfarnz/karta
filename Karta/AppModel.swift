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

    // ---------- provenance ----------
    private(set) var provenance: [ProvenanceRecord] = []

    // ---------- services ----------
    private let cache: ProviderCache
    private let elevation: ElevationService
    private let router: Router
    let discover: DiscoverService

    init() {
        let http = URLSessionFetcher()
        let cache = ProviderCache()
        let elevation = ElevationService(http: http, cache: cache)
        self.cache = cache
        self.elevation = elevation
        self.router = Router(http: http, elevation: elevation)
        self.discover = DiscoverService(http: http, cache: cache, elevation: elevation)
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

    func note(_ records: [ProvenanceRecord]) {
        for record in records { note(record) }
    }

    // ---------- housekeeping ----------

    func flushCaches() async {
        await cache.flushPoints()
        await cache.enforceBudget()
    }
}
