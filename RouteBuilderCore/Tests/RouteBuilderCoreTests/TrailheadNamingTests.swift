import Foundation
import Testing
@testable import RouteBuilderCore

@Suite("Trailhead naming")
struct TrailheadNamingTests {

    // ---------- which names are worth replacing ----------

    @Test func `the placeholder and blank names are uninformative`() {
        #expect(TrailheadNaming.isUninformative("Trailhead"))
        #expect(TrailheadNaming.isUninformative("trailhead"))
        #expect(TrailheadNaming.isUninformative(""))
        #expect(TrailheadNaming.isUninformative("   "))
    }

    // Gen06..Gen13 are GPS waypoint labels from a bulk import around Genesee
    // Mountain Park. They look deliberate, which makes them worse than blank.
    @Test func `single word names containing digits are machine labels`() {
        for junk in ["Gen10", "Gen06", "WPT001", "TH3", "001", "P12"] {
            #expect(TrailheadNaming.isUninformative(junk), "\(junk) should be replaced")
        }
    }

    // The test must not eat real names, which is the risk of a heuristic.
    @Test func `real trailhead names are kept`() {
        for good in ["Fowler Trailhead", "Jenny Creek Trailhead", "Chautauqua",
                     "C-470 Trail 4th Avenue Trailhead", "New Trail Connector",
                     "Mount Sanitas", "Four Mile Creek"] {
            #expect(!TrailheadNaming.isUninformative(good), "\(good) should be kept")
        }
    }

    // ---------- picking a name from what is nearby ----------

    private static let node = Coordinate(longitude: -105.29208, latitude: 40.02453)

    private func feature(_ name: String, _ kind: TrailheadNaming.NearbyFeature.Kind,
                         metresAway: Double, bearing: Double = 90)
        -> TrailheadNaming.NearbyFeature {
        TrailheadNaming.NearbyFeature(
            name: name, kind: kind,
            coordinate: Self.node.offset(bearingDegrees: bearing, distanceM: metresAway))
    }

    // The real case: the blank node above Boulder sits at the foot of the
    // Dakota Ridge Trail, inside a 45,000 acre open space. The trail is the
    // useful answer.
    @Test func `a nearby trail beats a huge enclosing park`() {
        let name = TrailheadNaming.bestName(for: Self.node, from: [
            feature("Boulder Open Space and Mountain Parks", .area, metresAway: 40),
            feature("Dakota Ridge Trail", .path, metresAway: 120),
        ])
        #expect(name == "Dakota Ridge Trail")
    }

    @Test func `with no trail nearby the park name is used`() {
        let name = TrailheadNaming.bestName(for: Self.node, from: [
            feature("Genesee Mountain Park", .area, metresAway: 300),
        ])
        #expect(name == "Genesee Mountain Park")
    }

    @Test func `among trails the nearest wins`() {
        let name = TrailheadNaming.bestName(for: Self.node, from: [
            feature("Aspen Alley Trail", .path, metresAway: 140),
            feature("Lookout Trail", .path, metresAway: 20),
            feature("Observatory Trail", .path, metresAway: 90),
        ])
        #expect(name == "Lookout Trail")
    }

    // The query asks at the widest radius, but a union query returns
    // everything near *any* node, so range is rechecked per point.
    @Test func `features beyond every tier are ignored`() {
        #expect(TrailheadNaming.bestName(for: Self.node, from: [
            feature("Far Away Trail", .path, metresAway: 600),
        ]) == nil)

        #expect(TrailheadNaming.bestName(for: Self.node, from: [
            feature("Distant Park", .area, metresAway: 2_000),
        ]) == nil)
    }

    // The tier order is the whole point: a close park beats a far trail,
    // because a trail 300 m away may serve a different access point.
    @Test func `a close park beats a distant trail`() {
        #expect(TrailheadNaming.bestName(for: Self.node, from: [
            feature("Far Away Trail", .path, metresAway: 380),
            feature("Genesee Mountain Park", .area, metresAway: 300),
        ]) == "Genesee Mountain Park")
    }

    // ...but a trail inside the near tier beats that same park.
    @Test func `a close trail still beats a close park`() {
        #expect(TrailheadNaming.bestName(for: Self.node, from: [
            feature("Lookout Trail", .path, metresAway: 140),
            feature("Genesee Mountain Park", .area, metresAway: 100),
        ]) == "Lookout Trail")
    }

    // The far tiers exist because they take the Boulder sample from 9 of 10
    // unnamed nodes named to 10 of 10.
    @Test func `a distant trail is used when nothing closer exists`() {
        #expect(TrailheadNaming.bestName(for: Self.node, from: [
            feature("Far Away Trail", .path, metresAway: 380),
        ]) == "Far Away Trail")

        #expect(TrailheadNaming.bestName(for: Self.node, from: [
            feature("Distant Park", .area, metresAway: 1_200),
        ]) == "Distant Park")
    }

    @Test func `nothing nearby yields nothing rather than a guess`() {
        #expect(TrailheadNaming.bestName(for: Self.node, from: []) == nil)
    }

    // ---------- the query ----------

    @Test func `the query covers every point and asks for centres`() {
        let points = [
            Coordinate(longitude: -105.29208, latitude: 40.02453),
            Coordinate(longitude: -105.30777, latitude: 39.72240),
        ]
        let query = TrailheadNaming.resolutionQuery(for: points)

        #expect(query.hasPrefix("[out:json]"))
        // `center` is what lets a way or relation be measured against a point.
        #expect(query.contains("out tags center"))
        for point in points {
            #expect(query.contains(String(format: "%.6f", point.latitude)))
            #expect(query.contains(String(format: "%.6f", point.longitude)))
        }
        #expect(query.contains("protected_area"))
        // The widest radius of each kind; tiers are applied when choosing.
        #expect(query.contains("400"))
        #expect(query.contains("1500"))
    }

    // Roads are named and useless: "3rd Street" is not a trailhead.
    @Test func `the query asks only for trail-like highways`() {
        let query = TrailheadNaming.resolutionQuery(
            for: [Coordinate(longitude: -105, latitude: 40)])
        #expect(query.contains("path"))
        #expect(query.contains("bridleway"))
        #expect(!query.contains("residential"))
        #expect(!query.contains("motorway"))
    }

    // ---------- decoding ----------

    @Test func `a way's centre is used and a node's own position otherwise`() {
        let body = #"""
        {"elements":[
          {"type":"way","center":{"lat":40.0246,"lon":-105.2919},
           "tags":{"name":"Dakota Ridge Trail","highway":"path"}},
          {"type":"relation","center":{"lat":39.7230,"lon":-105.3090},
           "tags":{"name":"Genesee Mountain Park","boundary":"protected_area"}},
          {"type":"way","center":{"lat":40.0,"lon":-105.0},"tags":{"highway":"path"}}
        ]}
        """#
        let decoded = try! JSONDecoder()
            .decode(OverpassCenterResponse.self, from: Data(body.utf8))
        let features = (decoded.elements ?? []).compactMap(\.feature)

        #expect(features.count == 2)  // the nameless way is dropped
        #expect(features[0].name == "Dakota Ridge Trail")
        #expect(features[0].kind == .path)
        #expect(features[1].name == "Genesee Mountain Park")
        #expect(features[1].kind == .area)
        #expect(abs(features[0].coordinate.latitude - 40.0246) < 1e-9)
    }
}

@Suite("Naming trailheads end to end")
struct TrailheadNamingServiceTests {

    private func tempCache() -> (ProviderCache, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rb-name-\(UUID().uuidString)", isDirectory: true)
        return (ProviderCache(directory: dir), dir)
    }

    private func service(_ http: FakeHTTP, _ cache: ProviderCache) -> DiscoverService {
        DiscoverService(http: http, cache: cache,
                        elevation: ElevationService(http: http, cache: cache))
    }

    /// The real Boulder response: some nodes named, some blank, some carrying
    /// GPS junk.
    ///
    /// The three are deliberately more than the picker's separation apart
    /// (a tenth of the radius), or it would correctly drop one as a
    /// duplicate anchor and the naming assertions would be testing that
    /// instead.
    private static let trailheads = #"""
    {"elements":[
      {"lon":-105.2921,"lat":40.0245,"tags":{"highway":"trailhead"}},
      {"lon":-105.3078,"lat":39.7224,"tags":{"highway":"trailhead","name":"Gen10"}},
      {"lon":-105.1000,"lat":39.9500,"tags":{"highway":"trailhead","name":"Fowler Trailhead"}}
    ]}
    """#

    /// What the resolution query returns for those two points.
    private static let nearby = #"""
    {"elements":[
      {"type":"way","center":{"lat":40.0246,"lon":-105.2919},
       "tags":{"name":"Dakota Ridge Trail","highway":"path"}},
      {"type":"relation","center":{"lat":39.7230,"lon":-105.3090},
       "tags":{"name":"Genesee Mountain Park","boundary":"protected_area"}}
    ]}
    """#

    private func http() -> FakeHTTP {
        FakeHTTP { url in
            // Both calls go to Overpass; the resolution query is the one
            // asking for centres.
            .json(Self.trailheads)
        }
    }

    @Test func `blank and junk names are replaced, real ones left alone`() async {
        let (cache, dir) = tempCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        // The fake has to tell the two Overpass calls apart, which it can
        // only do by body, so route on call order instead.
        let counter = CallCounter()
        let http = FakeHTTP { _ in
            counter.next() == 0 ? .json(Self.trailheads) : .json(Self.nearby)
        }

        let result = await service(http, cache).findTrailheads(
            center: Coordinate(longitude: -105.28, latitude: 39.995),
            radiusMiles: 30, limit: 5)

        let names = result.trailheads.map(\.name).sorted()
        #expect(names == ["Dakota Ridge Trail", "Fowler Trailhead", "Genesee Mountain Park"])
    }

    // A naming failure must not take the search down with it.
    @Test func `a failed name lookup leaves the original names`() async {
        let (cache, dir) = tempCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let counter = CallCounter()
        let http = FakeHTTP { _ in
            counter.next() == 0 ? .json(Self.trailheads) : .failure
        }

        let result = await service(http, cache).findTrailheads(
            center: Coordinate(longitude: -105.28, latitude: 39.995),
            radiusMiles: 30, limit: 5)

        #expect(result.trailheads.count == 3)
        #expect(result.trailheads.contains { $0.name == "Fowler Trailhead" })
        #expect(result.trailheads.contains { $0.name == "Trailhead" })
        #expect(result.trailheads.contains { $0.name == "Gen10" })
    }

    // Every anchor already named means no reason to call Overpass again.
    @Test func `a fully named set makes no second request`() async {
        let (cache, dir) = tempCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let body = #"""
        {"elements":[
          {"lon":-105.28,"lat":39.99,"tags":{"highway":"trailhead","name":"Fowler Trailhead"}},
          {"lon":-105.29,"lat":39.98,"tags":{"highway":"trailhead","name":"Mesa Trailhead"}}
        ]}
        """#
        let http = FakeHTTP { _ in .json(body) }
        _ = await service(http, cache).findTrailheads(
            center: Coordinate(longitude: -105.28, latitude: 39.995),
            radiusMiles: 30, limit: 5)

        #expect(await http.requestedURLs.count == 1)
    }
}

/// Call-order routing for a fake that cannot tell requests apart by URL.
final class CallCounter: @unchecked Sendable {
    private var count = 0
    private let lock = NSLock()
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        defer { count += 1 }
        return count
    }
}
