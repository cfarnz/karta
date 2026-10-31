import Foundation

/// Route discovery: find trailheads near a point, generate candidate loops
/// from each, then score and filter them against the user's sliders.

public struct Trailhead: Sendable, Equatable, Identifiable {
    public var coordinate: Coordinate
    public var name: String
    /// Straight-line distance from the search centre, in metres.
    public var distanceFromCenterM: Double
    public var elevationFt: Double?

    public var id: String { "\(coordinate.longitude),\(coordinate.latitude)" }
}

public struct Candidate: Sendable, Identifiable {
    public var name: String
    public var coordinates: [Coordinate]
    /// The via-points the loop was built from, kept so the route can be
    /// reopened as an editable set of waypoints rather than a frozen track.
    public var vias: [Coordinate]
    public var distanceMiles: Double
    public var gainFeet: Double
    /// High point, in feet.
    public var highPointFt: Double
    public var effort: Double
    public var driveMiles: Double

    public var id: String {
        "\(name)-\(String(format: "%.3f", distanceMiles))-\(String(format: "%.0f", gainFeet))"
    }
}

public struct DiscoverOptions: Sendable {
    public var center: Coordinate
    public var targetMiles: Double
    public var maxEffort: Double
    public var highPointMinFt: Double
    public var highPointMaxFt: Double
    public var radiusMiles: Double
    /// Skips the current-location anchor and keeps only high trailheads.
    public var mountainsOnly: Bool

    public init(
        center: Coordinate,
        targetMiles: Double,
        maxEffort: Double,
        highPointMinFt: Double,
        highPointMaxFt: Double,
        radiusMiles: Double,
        mountainsOnly: Bool
    ) {
        self.center = center
        self.targetMiles = targetMiles
        self.maxEffort = maxEffort
        self.highPointMinFt = highPointMinFt
        self.highPointMaxFt = highPointMaxFt
        self.radiusMiles = radiusMiles
        self.mountainsOnly = mountainsOnly
    }
}

/// Effort as one number, so distance and climbing trade off against each
/// other: 500 ft of gain costs about what another mile costs.
public enum Effort {
    public static func score(distanceMiles: Double, gainFeet: Double) -> Double {
        distanceMiles + gainFeet / 500
    }

    public enum Bucket: String, Sendable {
        case easy = "Easy"
        case moderate = "Moderate"
        case hard = "Hard"
        case veryHard = "Very Hard"
    }

    public static func bucket(_ score: Double) -> Bucket {
        switch score {
        case ..<8: .easy
        case ..<14: .moderate
        case ..<20: .hard
        default: .veryHard
        }
    }
}

/// Injected so tests get deterministic loop bearings and trailhead picks.
/// The web app called Math.random inline, which made Discover impossible to
/// test and its bugs impossible to reproduce.
public protocol RandomSource: Sendable {
    /// Uniform in 0..<1.
    func next() -> Double
}

public struct SystemRandom: RandomSource {
    public init() {}
    public func next() -> Double { Double.random(in: 0..<1) }
}

/// Fixed sequence, cycling. For tests.
public struct FixedRandom: RandomSource {
    private let values: [Double]
    private let counter = Counter()

    final class Counter: @unchecked Sendable {
        private var index = 0
        private let lock = NSLock()
        func next(modulo n: Int) -> Int {
            lock.lock(); defer { lock.unlock() }
            let i = index % n
            index += 1
            return i
        }
    }

    public init(_ values: [Double]) {
        self.values = values.isEmpty ? [0.5] : values
    }

    public func next() -> Double { values[counter.next(modulo: values.count)] }
}

public actor DiscoverService {
    private let http: HTTPFetching
    private let cache: ProviderCache
    private let elevation: ElevationService
    private let random: RandomSource

    private static let overpass = "https://overpass-api.de/api/interpreter"
    private static let brouter = "https://brouter.de/brouter"

    /// Trailheads above this are "mountains" in Colorado terms — foothills
    /// trailheads (Chautauqua ~5,700 ft) fall below, high country sits above.
    public static let mountainTrailheadFt = 8000.0

    /// Trail networks make loops come back far longer than circle geometry
    /// predicts — measured 1.5 to 8x in the Front Range — so a candidate is
    /// routed, measured, and resized up to this many times.
    static let loopAttempts = 3
    /// Within this fraction of target, stop refining.
    static let loopTolerance = 0.3
    /// Candidates outside this fraction of target are discarded.
    static let distanceTolerance = 0.3
    static let workerCount = 4

    public init(
        http: HTTPFetching,
        cache: ProviderCache,
        elevation: ElevationService,
        random: RandomSource = SystemRandom()
    ) {
        self.http = http
        self.cache = cache
        self.elevation = elevation
        self.random = random
    }

    // ---------- trailheads ----------

    private struct OverpassResponse: Codable, Sendable {
        struct Element: Codable, Sendable {
            var lon: Double
            var lat: Double
            var tags: [String: String]?
        }
        var elements: [Element]?
    }

    static func overpassQuery(center: Coordinate, radiusMiles: Double) -> String {
        let radiusM = Int((radiusMiles * Units.metersPerMile).rounded())
        let around = "(around:\(radiusM),\(center.latitude),\(center.longitude))"
        return """
        [out:json][timeout:25];\
        (node["information"="trailhead"]\(around);\
        node["highway"="trailhead"]\(around););\
        out 150;
        """
    }

    /// Overpass is rate-limited and goes down often, so trailhead queries are
    /// cached for a week and keyed to a ~1 km grid: nudging your position or
    /// the radius slider by a hair reuses the answer instead of re-querying.
    static func trailheadCacheKey(center: Coordinate, radiusMiles: Double) -> String {
        "trailheads:\(String(format: "%.2f", center.longitude)),"
            + "\(String(format: "%.2f", center.latitude)):"
            + "\(Int(radiusMiles.rounded()))"
    }

    public struct TrailheadResult: Sendable {
        public var trailheads: [Trailhead]
        public var provenance: ProvenanceRecord
    }

    private func fetchTrailheads(
        center: Coordinate,
        radiusMiles: Double
    ) async throws -> CacheHit<[OverpassResponse.Element]> {
        let key = Self.trailheadCacheKey(center: center, radiusMiles: radiusMiles)
        return try await cache.cached(key: key, ttl: TTL.trailheads) {
            var request = URLRequest(url: URL(string: Self.overpass)!)
            request.httpMethod = "POST"
            request.httpBody = Data(
                Self.overpassQuery(center: center, radiusMiles: radiusMiles).utf8)
            let data = try await http.data(for: request)
            return try JSONDecoder().decode(OverpassResponse.self, from: data).elements ?? []
        }
    }

    /// Real trailheads within radius, sampled *across* the whole radius — one
    /// pick per distance band, so a big radius reaches the far mountains
    /// instead of always anchoring on the five trailheads nearest home.
    public func findTrailheads(
        center: Coordinate,
        radiusMiles: Double,
        limit: Int = 5,
        mountainsOnly: Bool = false
    ) async -> TrailheadResult {
        let hit: CacheHit<[OverpassResponse.Element]>
        do {
            hit = try await fetchTrailheads(center: center, radiusMiles: radiusMiles)
        } catch {
            return TrailheadResult(
                trailheads: [],
                provenance: .init(dataset: "Trailheads", provider: "OSM Overpass",
                                  detail: "unreachable", isStale: true))
        }

        var nodes = hit.value.map { element in
            let coordinate = Coordinate(longitude: element.lon, latitude: element.lat)
            return Trailhead(
                coordinate: coordinate,
                name: element.tags?["name"] ?? "Trailhead",
                distanceFromCenterM: center.distance(to: coordinate),
                elevationFt: nil
            )
        }

        let provenance = ProvenanceRecord(
            dataset: "Trailheads",
            provider: "OSM Overpass",
            detail: "\(hit.value.count) within \(Int(radiusMiles.rounded())) mi",
            at: hit.fetchedAt,
            isStale: hit.isStale,
            fromCache: hit.fromCache
        )

        guard !nodes.isEmpty else {
            return TrailheadResult(trailheads: [], provenance: provenance)
        }

        if mountainsOnly {
            let result = await elevation.elevations(for: nodes.map(\.coordinate))
            for (index, metres) in result.values.enumerated() where index < nodes.count {
                nodes[index].elevationFt = metres * Units.feetPerMeter
            }
            nodes = nodes.filter { ($0.elevationFt ?? 0) >= Self.mountainTrailheadFt }
            guard !nodes.isEmpty else {
                return TrailheadResult(trailheads: [], provenance: provenance)
            }
        }

        return TrailheadResult(
            trailheads: pickAcrossBands(nodes, radiusMiles: radiusMiles, limit: limit),
            provenance: provenance
        )
    }

    /// One trailhead per distance band, near to far, each far enough from the
    /// ones already picked that the suggestions are not five variations on the
    /// same parking lot.
    /// Keeps suggestions from collapsing into five variations on the same
    /// parking lot. Takes the picked list explicitly rather than capturing it:
    /// a nested function closing over a mutable local reads as escaping to
    /// Swift 6's region isolation.
    static func isFarEnough(
        _ node: Trailhead,
        from picked: [Trailhead],
        separationM: Double
    ) -> Bool {
        picked.allSatisfy { $0.coordinate.distance(to: node.coordinate) > separationM }
    }

    /// Pure apart from the injected random source, so it needs no actor hop.
    nonisolated func pickAcrossBands(
        _ nodes: [Trailhead],
        radiusMiles: Double,
        limit: Int
    ) -> [Trailhead] {
        guard limit > 0 else { return [] }
        let separationM = max(2, radiusMiles / 10) * Units.metersPerMile
        let bandM = (radiusMiles * Units.metersPerMile) / Double(limit)

        var picked: [Trailhead] = []

        for band in 0..<limit {
            let inBand = nodes.filter {
                $0.distanceFromCenterM >= Double(band) * bandM
                    && $0.distanceFromCenterM < Double(band + 1) * bandM
                    && Self.isFarEnough($0, from: picked, separationM: separationM)
            }
            guard !inBand.isEmpty else { continue }
            let choice = Swift.min(inBand.count - 1, Int(random.next() * Double(inBand.count)))
            picked.append(inBand[choice])
        }

        // Backfill from anywhere if some bands were empty.
        for node in nodes.shuffled(using: random) where picked.count < limit {
            if Self.isFarEnough(node, from: picked, separationM: separationM) {
                picked.append(node)
            }
        }
        return picked
    }

    // ---------- candidate loops ----------

    private struct GeoJSON: Decodable {
        struct Feature: Decodable {
            struct Geometry: Decodable { var coordinates: [[Double]] }
            var geometry: Geometry
        }
        var features: [Feature]
    }

    /// Three via-points on a circle tangent to the anchor, so the route leaves
    /// and returns to the same trailhead.
    static func loopVias(anchor: Coordinate, bearing: Double, radiusM: Double) -> [Coordinate] {
        let center = anchor.offset(bearingDegrees: bearing, distanceM: radiusM)
        let back = (bearing + 180).truncatingRemainder(dividingBy: 360)
        let v1 = center.offset(
            bearingDegrees: (back + 120).truncatingRemainder(dividingBy: 360), distanceM: radiusM)
        let v2 = center.offset(
            bearingDegrees: (back + 240).truncatingRemainder(dividingBy: 360), distanceM: radiusM)
        return [anchor, v1, v2, anchor]
    }

    private func routeLoop(vias: [Coordinate]) async throws -> [Coordinate] {
        let lonlats = vias.map {
            "\(String(format: "%.6f", $0.longitude)),\(String(format: "%.6f", $0.latitude))"
        }.joined(separator: "|")

        var components = URLComponents(string: Self.brouter)
        components?.queryItems = [
            .init(name: "lonlats", value: lonlats),
            .init(name: "profile", value: "hiking-mountain"),
            .init(name: "alternativeidx", value: "0"),
            .init(name: "format", value: "geojson"),
        ]
        guard let url = components?.url else {
            throw HTTPError(statusCode: -1, source: "BRouter")
        }

        let data = try await http.data(from: url)
        let raw = try JSONDecoder().decode(GeoJSON.self, from: data)
            .features.first?.geometry.coordinates ?? []
        guard raw.count >= 2 else { throw HTTPError(statusCode: 204, source: "BRouter") }

        return raw.compactMap {
            guard $0.count >= 2 else { return nil }
            return Coordinate(longitude: $0[0], latitude: $0[1],
                              elevation: $0.count > 2 ? $0[2] : nil)
        }
    }

    /// One candidate loop, adaptively sized: route it, measure it, scale the
    /// circle by target/actual, retry.
    private func adaptiveLoop(
        anchor: Coordinate,
        targetMiles: Double,
        bearing: Double
    ) async throws -> (coordinates: [Coordinate], vias: [Coordinate]) {
        let targetM = targetMiles * Units.metersPerMile
        // Start small: mountains inflate loop length, so overshooting wastes
        // the attempt budget more often than undershooting does.
        var radiusM = (targetM / (2 * .pi)) * 0.8

        var best: (coordinates: [Coordinate], vias: [Coordinate])?
        var bestError = Double.infinity

        for _ in 0..<Self.loopAttempts {
            try Task.checkCancellation()

            let vias = Self.loopVias(anchor: anchor, bearing: bearing, radiusM: radiusM)
            let coordinates = try await routeLoop(vias: vias)
            let actualM = coordinates.trackLengthM
            guard actualM > 0 else { break }

            let error = abs(actualM - targetM) / targetM
            if error < bestError {
                best = (coordinates, vias)
                bestError = error
            }
            if error <= Self.loopTolerance { return (coordinates, vias) }

            // Scale toward target, clamped so one weird result cannot zero it.
            radiusM *= min(1.6, max(0.25, targetM / actualM))
        }

        guard let best else { throw HTTPError(statusCode: 204, source: "BRouter") }
        return best  // the caller's distance filter makes the final call
    }

    static func trackStats(_ coordinates: [Coordinate])
        -> (distanceMiles: Double, gainFeet: Double, highPointFt: Double) {
        let stats = RouteState.stats(for: coordinates)
        let highestM = coordinates.compactMap(\.elevation).max() ?? 0
        return (stats.distanceMiles, stats.gainFeet, highestM * Units.feetPerMeter)
    }

    // ---------- the search ----------

    public struct DiscoverResult: Sendable {
        public var candidates: [Candidate]
        public var provenance: [ProvenanceRecord]
    }

    /// Generate, filter and rank candidate loops.
    ///
    /// `onProgress` reports (completed, total) so the UI can show a real bar
    /// rather than a spinner over a search that can take half a minute.
    public func discover(
        _ options: DiscoverOptions,
        onProgress: @Sendable (Int, Int) -> Void = { _, _ in }
    ) async -> DiscoverResult {
        var provenance: [ProvenanceRecord] = []

        // Mountains-only skips the current-location anchor — that's the city.
        var anchors: [Trailhead] = options.mountainsOnly ? [] : [
            Trailhead(coordinate: options.center, name: "Current location",
                      distanceFromCenterM: 0, elevationFt: nil)
        ]

        let found = await findTrailheads(
            center: options.center,
            radiusMiles: options.radiusMiles,
            limit: options.mountainsOnly ? 6 : 5,
            mountainsOnly: options.mountainsOnly
        )
        provenance.append(found.provenance)
        anchors.append(contentsOf: found.trailheads)

        guard !anchors.isEmpty else {
            return DiscoverResult(candidates: [], provenance: provenance)
        }

        // Two loop directions per anchor, jittered so reruns give fresh options.
        var bearings = [0.0, 90, 180, 270].shuffled(using: random).prefix(2).map { $0 }
        if bearings.isEmpty { bearings = [0, 180] }

        struct Job: Sendable {
            var anchor: Trailhead
            var bearing: Double
        }
        var jobs: [Job] = []
        for anchor in anchors {
            for bearing in bearings {
                jobs.append(Job(anchor: anchor, bearing: bearing + random.next() * 40 - 20))
            }
        }

        let total = jobs.count
        let candidates = await withTaskGroup(
            of: Candidate?.self, returning: [Candidate].self
        ) { group in
            var out: [Candidate] = []
            var next = 0
            var completed = 0

            func addNext() {
                guard next < jobs.count else { return }
                let job = jobs[next]
                next += 1
                group.addTask { [self] in
                    guard let loop = try? await adaptiveLoop(
                        anchor: job.anchor.coordinate,
                        targetMiles: options.targetMiles,
                        bearing: job.bearing
                    ) else { return nil }

                    let stats = Self.trackStats(loop.coordinates)
                    let effort = Effort.score(distanceMiles: stats.distanceMiles,
                                              gainFeet: stats.gainFeet)

                    let keep = abs(stats.distanceMiles - options.targetMiles)
                            <= options.targetMiles * Self.distanceTolerance
                        && effort <= options.maxEffort
                        && stats.highPointFt >= options.highPointMinFt
                        && stats.highPointFt <= options.highPointMaxFt
                    guard keep else { return nil }

                    return Candidate(
                        name: job.anchor.name,
                        coordinates: loop.coordinates,
                        vias: loop.vias,
                        distanceMiles: stats.distanceMiles,
                        gainFeet: stats.gainFeet,
                        highPointFt: stats.highPointFt,
                        effort: effort,
                        driveMiles: options.center.distance(to: job.anchor.coordinate)
                            / Units.metersPerMile
                    )
                }
            }

            for _ in 0..<min(Self.workerCount, jobs.count) { addNext() }

            while let candidate = await group.next() {
                if let candidate { out.append(candidate) }
                completed += 1
                onProgress(completed, total)
                addNext()
            }
            return out
        }

        // Closest to the requested distance first.
        let ranked = candidates.sorted {
            abs($0.distanceMiles - options.targetMiles)
                < abs($1.distanceMiles - options.targetMiles)
        }
        return DiscoverResult(candidates: Array(ranked.prefix(10)), provenance: provenance)
    }
}

extension Array {
    /// Deterministic shuffle driven by the injected random source.
    func shuffled(using random: RandomSource) -> [Element] {
        guard count > 1 else { return self }
        var out = self
        for i in stride(from: out.count - 1, to: 0, by: -1) {
            let j = Swift.min(i, Int(random.next() * Double(i + 1)))
            out.swapAt(i, j)
        }
        return out
    }
}
