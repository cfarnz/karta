import Foundation
import Testing
@testable import RouteBuilderCore

private func tempCache() -> (ProviderCache, URL) {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("rb-disc-\(UUID().uuidString)", isDirectory: true)
    return (ProviderCache(directory: dir), dir)
}

/// Metres per degree of longitude at latitude 40, close enough to build a
/// track of a chosen length for the fake router to return.
private let metersPerDegreeLon = 111_320.0 * cos(40 * .pi / 180)

/// A BRouter loop body of roughly `miles`, climbing to `highPointM`.
private func loopBody(miles: Double, highPointM: Double, lat: Double = 40) -> String {
    let span = (miles * Units.metersPerMile) / 2 / metersPerDegreeLon
    let points = [
        (-105.0, lat, 2000.0),
        (-105.0 + span, lat, highPointM),
        (-105.0, lat, 2000.0),
    ]
    let coords = points.map { "[\($0.0),\($0.1),\($0.2)]" }.joined(separator: ",")
    return #"{"features":[{"geometry":{"coordinates":[\#(coords)]}}]}"#
}

private func overpassBody(_ nodes: [(Double, Double, String)]) -> String {
    let elements = nodes.map {
        #"{"lon":\#($0.0),"lat":\#($0.1),"tags":{"name":"\#($0.2)"}}"#
    }.joined(separator: ",")
    return #"{"elements":[\#(elements)]}"#
}

private let boulder = Coordinate(longitude: -105.2811, latitude: 39.9992)

@Suite("Effort scoring")
struct EffortTests {

    // 500 ft of climbing costs about what another mile costs.
    @Test func `gain trades off against distance at five hundred feet per mile`() {
        #expect(Effort.score(distanceMiles: 10, gainFeet: 0) == 10)
        #expect(Effort.score(distanceMiles: 10, gainFeet: 500) == 11)
        #expect(Effort.score(distanceMiles: 0, gainFeet: 2500) == 5)
    }

    @Test(arguments: [
        (0.0, Effort.Bucket.easy),
        (7.9, .easy),
        (8.0, .moderate),
        (13.9, .moderate),
        (14.0, .hard),
        (19.9, .hard),
        (20.0, .veryHard),
        (40.0, .veryHard),
    ])
    func `buckets fall on the documented boundaries`(score: Double, expected: Effort.Bucket) {
        #expect(Effort.bucket(score) == expected)
    }

    @Test func `a real Sawatch-scale day lands in Very Hard`() {
        // 31 mi, 7,000 ft -> 31 + 14 = 45.
        #expect(Effort.bucket(Effort.score(distanceMiles: 31, gainFeet: 7000)) == .veryHard)
    }
}

@Suite("Overpass query and cache key")
struct OverpassTests {

    @Test func `the query asks for both trailhead taggings`() {
        let q = DiscoverService.overpassQuery(center: boulder, radiusMiles: 25)
        // OSM tags trailheads two ways and both are common in Colorado.
        #expect(q.contains(#"node["information"="trailhead"]"#))
        #expect(q.contains(#"node["highway"="trailhead"]"#))
        #expect(q.contains("around:40234"))  // 25 mi in metres
        #expect(q.contains("out 150;"))
    }

    // Overpass is rate-limited and goes down often, so nudging the position or
    // the radius slider by a hair must reuse the same answer.
    @Test func `nearby centres and radii share one cache key`() {
        let a = DiscoverService.trailheadCacheKey(
            center: Coordinate(longitude: -105.2811, latitude: 39.9992), radiusMiles: 25.2)
        let b = DiscoverService.trailheadCacheKey(
            center: Coordinate(longitude: -105.2834, latitude: 39.9971), radiusMiles: 24.8)
        #expect(a == b)
    }

    @Test func `genuinely different searches do not share a key`() {
        let boulderKey = DiscoverService.trailheadCacheKey(center: boulder, radiusMiles: 25)
        let farKey = DiscoverService.trailheadCacheKey(
            center: Coordinate(longitude: -107.81, latitude: 37.94), radiusMiles: 25)
        let wideKey = DiscoverService.trailheadCacheKey(center: boulder, radiusMiles: 60)
        #expect(boulderKey != farKey)
        #expect(boulderKey != wideKey)
    }
}

@Suite("Loop geometry")
struct LoopGeometryTests {

    @Test func `a loop leaves from and returns to the anchor`() {
        let vias = DiscoverService.loopVias(anchor: boulder, bearing: 45, radiusM: 2000)
        #expect(vias.count == 4)
        #expect(vias.first == boulder)
        #expect(vias.last == boulder)
    }

    @Test func `the three circle points are evenly spread around the anchor`() {
        let radius = 2000.0
        let vias = DiscoverService.loopVias(anchor: boulder, bearing: 0, radiusM: radius)
        let center = boulder.offset(bearingDegrees: 0, distanceM: radius)

        // All three via-points sit on the circle.
        for via in [vias[0], vias[1], vias[2]] {
            #expect(abs(center.distance(to: via) - radius) < 1.0)
        }
        // And 120 degrees apart, so the loop is a loop rather than a there-and-back.
        #expect(abs(vias[1].distance(to: vias[2]) - radius * sqrt(3)) < 5.0)
    }

    @Test func `bearing rotates the loop without resizing it`() {
        let north = DiscoverService.loopVias(anchor: boulder, bearing: 0, radiusM: 3000)
        let east = DiscoverService.loopVias(anchor: boulder, bearing: 90, radiusM: 3000)
        #expect(north[1] != east[1])
        #expect(abs(north[1].distance(to: north[2]) - east[1].distance(to: east[2])) < 5.0)
    }
}

@Suite("Trailhead band sampling")
struct BandSamplingTests {

    private func trailhead(_ distanceMi: Double, _ name: String, lonOffset: Double) -> Trailhead {
        let coordinate = boulder.offset(bearingDegrees: 90, distanceM: distanceMi * Units.metersPerMile)
        return Trailhead(
            coordinate: Coordinate(longitude: coordinate.longitude + lonOffset,
                                   latitude: coordinate.latitude),
            name: name,
            distanceFromCenterM: distanceMi * Units.metersPerMile,
            elevationFt: nil)
    }

    // The whole point of banding: a 50-mile radius should reach the far
    // mountains, not return five variations on the nearest parking lot.
    @Test func `picks span the radius instead of clustering near home`() {
        let nodes = (1...50).map { trailhead(Double($0), "th\($0)", lonOffset: 0) }
        let service = DiscoverService(
            http: FakeHTTP { _ in .failure },
            cache: ProviderCache(directory: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("rb-band-\(UUID().uuidString)")),
            elevation: ElevationService(
                http: FakeHTTP { _ in .failure },
                cache: ProviderCache(directory: URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("rb-band2-\(UUID().uuidString)"))),
            random: FixedRandom([0.5]))

        let picked = service.pickAcrossBands(nodes, radiusMiles: 50, limit: 5)
        #expect(picked.count == 5)

        let miles = picked.map { $0.distanceFromCenterM / Units.metersPerMile }.sorted()
        // One per 10-mile band, so the farthest pick is genuinely far out.
        #expect(miles.first! < 15)
        #expect(miles.last! > 35)
    }

    @Test func `picks stay separated from each other`() {
        // Twenty trailheads crammed into the same square mile.
        let nodes = (1...20).map { trailhead(5, "th\($0)", lonOffset: Double($0) * 0.0001) }
        let service = DiscoverService(
            http: FakeHTTP { _ in .failure },
            cache: ProviderCache(directory: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("rb-sep-\(UUID().uuidString)")),
            elevation: ElevationService(
                http: FakeHTTP { _ in .failure },
                cache: ProviderCache(directory: URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("rb-sep2-\(UUID().uuidString)"))),
            random: FixedRandom([0.0]))

        let picked = service.pickAcrossBands(nodes, radiusMiles: 50, limit: 5)
        // Separation is max(2, radius/10) = 5 mi here, and they are all within
        // 0.002 degrees of each other, so only one can survive.
        #expect(picked.count == 1)
    }

    @Test func `asking for none returns none`() {
        let service = DiscoverService(
            http: FakeHTTP { _ in .failure },
            cache: ProviderCache(directory: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("rb-zero-\(UUID().uuidString)")),
            elevation: ElevationService(
                http: FakeHTTP { _ in .failure },
                cache: ProviderCache(directory: URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("rb-zero2-\(UUID().uuidString)"))),
            random: FixedRandom([0.5]))
        #expect(service.pickAcrossBands([trailhead(5, "a", lonOffset: 0)],
                                        radiusMiles: 50, limit: 0).isEmpty)
    }
}

@Suite("Discover end to end")
struct DiscoverEndToEndTests {

    private func makeService(_ http: FakeHTTP, random: RandomSource = FixedRandom([0.5]))
        -> (DiscoverService, URL) {
        let (cache, dir) = tempCache()
        return (DiscoverService(
            http: http,
            cache: cache,
            elevation: ElevationService(http: http, cache: cache),
            random: random), dir)
    }

    @Test func `candidates near the target distance are kept and ranked`() async {
        let http = FakeHTTP { url in
            if url.host == "overpass-api.de" {
                return .json(overpassBody([(-105.30, 40.01, "Chautauqua")]))
            }
            return .json(loopBody(miles: 10, highPointM: 2600))
        }
        let (service, dir) = makeService(http)
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = await service.discover(.init(
            center: boulder, targetMiles: 10, maxEffort: 40,
            highPointMinFt: 0, highPointMaxFt: 20000,
            radiusMiles: 25, mountainsOnly: false))

        #expect(!result.candidates.isEmpty)
        let first = try! #require(result.candidates.first)
        #expect(abs(first.distanceMiles - 10) < 1)
        #expect(first.highPointFt > 8000)  // 2,600 m
    }

    @Test func `candidates outside the distance tolerance are discarded`() async {
        let http = FakeHTTP { url in
            if url.host == "overpass-api.de" {
                return .json(overpassBody([(-105.30, 40.01, "Chautauqua")]))
            }
            // Every attempt comes back at 30 mi against a 10 mi target.
            return .json(loopBody(miles: 30, highPointM: 2600))
        }
        let (service, dir) = makeService(http)
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = await service.discover(.init(
            center: boulder, targetMiles: 10, maxEffort: 100,
            highPointMinFt: 0, highPointMaxFt: 20000,
            radiusMiles: 25, mountainsOnly: false))

        #expect(result.candidates.isEmpty)
    }

    @Test func `the high-point filter rejects loops that stay too low`() async {
        let http = FakeHTTP { url in
            if url.host == "overpass-api.de" {
                return .json(overpassBody([(-105.30, 40.01, "Foothills TH")]))
            }
            return .json(loopBody(miles: 10, highPointM: 2000))  // ~6,560 ft
        }
        let (service, dir) = makeService(http)
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = await service.discover(.init(
            center: boulder, targetMiles: 10, maxEffort: 100,
            highPointMinFt: 12000, highPointMaxFt: 15000,  // wants a 12er
            radiusMiles: 25, mountainsOnly: false))

        #expect(result.candidates.isEmpty)
    }

    @Test func `the effort ceiling rejects loops that climb too much`() async {
        let http = FakeHTTP { url in
            if url.host == "overpass-api.de" {
                return .json(overpassBody([(-105.30, 40.01, "Steep TH")]))
            }
            // 10 mi with ~5,250 ft of gain -> effort ~20.5
            return .json(loopBody(miles: 10, highPointM: 3600))
        }
        let (service, dir) = makeService(http)
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = await service.discover(.init(
            center: boulder, targetMiles: 10, maxEffort: 12,
            highPointMinFt: 0, highPointMaxFt: 20000,
            radiusMiles: 25, mountainsOnly: false))

        #expect(result.candidates.isEmpty)
    }

    @Test func `progress is reported once per job and reaches the total`() async {
        let http = FakeHTTP { url in
            if url.host == "overpass-api.de" {
                return .json(overpassBody([(-105.30, 40.01, "A"), (-105.50, 40.20, "B")]))
            }
            return .json(loopBody(miles: 10, highPointM: 2600))
        }
        let (service, dir) = makeService(http)
        defer { try? FileManager.default.removeItem(at: dir) }

        let reports = Reports()
        _ = await service.discover(.init(
            center: boulder, targetMiles: 10, maxEffort: 40,
            highPointMinFt: 0, highPointMaxFt: 20000,
            radiusMiles: 25, mountainsOnly: false)) { done, total in
                reports.add(done, total)
            }

        let seen = reports.snapshot
        #expect(!seen.isEmpty)
        // A real progress bar needs the last report to actually land on 100%.
        #expect(seen.last?.0 == seen.last?.1)
        #expect(seen.map(\.0) == Array(1...seen.count))
    }

    @Test func `no trailheads and no fallback anchor yields nothing`() async {
        let http = FakeHTTP { url in
            url.host == "overpass-api.de" ? .json(#"{"elements":[]}"#) : .failure
        }
        let (service, dir) = makeService(http)
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = await service.discover(.init(
            center: boulder, targetMiles: 10, maxEffort: 40,
            highPointMinFt: 0, highPointMaxFt: 20000,
            radiusMiles: 25, mountainsOnly: true))  // skips current location

        #expect(result.candidates.isEmpty)
    }

    @Test func `a dead Overpass still searches from the current location`() async {
        let http = FakeHTTP { url in
            if url.host == "overpass-api.de" { return .failure }
            return .json(loopBody(miles: 8, highPointM: 2600))
        }
        let (service, dir) = makeService(http)
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = await service.discover(.init(
            center: boulder, targetMiles: 8, maxEffort: 40,
            highPointMinFt: 0, highPointMaxFt: 20000,
            radiusMiles: 25, mountainsOnly: false))

        // Degraded, not empty: you can still get a loop from where you stand.
        #expect(!result.candidates.isEmpty)
        #expect(result.provenance.contains { $0.isStale })
    }
}

/// Thread-safe collector for the progress callback, which fires from the task
/// group rather than the caller's context.
final class Reports: @unchecked Sendable {
    private var items: [(Int, Int)] = []
    private let lock = NSLock()

    func add(_ done: Int, _ total: Int) {
        lock.lock(); defer { lock.unlock() }
        items.append((done, total))
    }

    var snapshot: [(Int, Int)] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
}
