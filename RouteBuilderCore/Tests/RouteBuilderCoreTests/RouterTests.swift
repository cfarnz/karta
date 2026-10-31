import Foundation
import Testing
@testable import RouteBuilderCore

private func tempCache() -> (ProviderCache, URL) {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("rb-router-\(UUID().uuidString)", isDirectory: true)
    return (ProviderCache(directory: dir), dir)
}

/// A BRouter GeoJSON body for the given [lon, lat, ele] triples.
private func brouterBody(_ points: [(Double, Double, Double)]) -> String {
    let coords = points.map { "[\($0.0),\($0.1),\($0.2)]" }.joined(separator: ",")
    return #"{"features":[{"geometry":{"coordinates":[\#(coords)]}}]}"#
}

private func openMeteoBody(_ url: URL, value: Double) -> String {
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let n = (query.first { $0.name == "latitude" }?.value ?? "").split(separator: ",").count
    return #"{"elevation":[\#((0..<n).map { _ in "\(value)" }.joined(separator: ","))]}"#
}

private func makeRouter(_ http: FakeHTTP, _ cache: ProviderCache) -> Router {
    Router(http: http, elevation: ElevationService(http: http, cache: cache))
}

private let start = Coordinate(longitude: -105.2811, latitude: 39.9992)
private let end = Coordinate(longitude: -105.2928, latitude: 39.9865)

@Suite("Routing a leg")
struct RouterTests {

    @Test func `a reasonable snapped path is used as-is`() async {
        let (cache, dir) = tempCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let http = FakeHTTP { url in
            #expect(url.host == "brouter.de")
            // A trail that wanders a little but stays well under 3x.
            return .json(brouterBody([
                (-105.2811, 39.9992, 1760),
                (-105.2860, 39.9940, 1850),
                (-105.2928, 39.9865, 2100),
            ]))
        }

        let result = await makeRouter(http, cache).routeLeg(from: start, to: end)

        #expect(result.leg.isStraight == false)
        #expect(result.leg.coordinates.count == 3)
        #expect(result.leg.coordinates.last?.elevation == 2100)
        #expect(result.provenance.detail == "snapped to trail")
        #expect(result.provenance.isStale == false)
    }

    @Test func `BRouter's elevations are carried through to the leg`() async {
        let (cache, dir) = tempCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let http = FakeHTTP { _ in
            .json(brouterBody([(-105.2811, 39.9992, 1760), (-105.2928, 39.9865, 2100)]))
        }
        let result = await makeRouter(http, cache).routeLeg(from: start, to: end)
        // No elevation lookup needed — the router already answered.
        #expect(await http.requestCount == 1)
        #expect(result.leg.coordinates.map(\.elevation) == [1760, 2100])
    }

    // The three outcomes look identical on the map and mean very different
    // things on the ground, so each has to be distinguishable afterwards.
    @Test func `a wildly indirect path is rejected for a straight line`() async {
        let (cache, dir) = tempCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let http = FakeHTTP { url in
            if url.host == "brouter.de" {
                // A detour an order of magnitude longer than the direct line:
                // the router found *a* trail, just not one between these points.
                return .json(brouterBody([
                    (-105.2811, 39.9992, 1760),
                    (-105.1000, 40.1000, 1900),
                    (-105.4000, 39.8000, 2000),
                    (-105.2928, 39.9865, 2100),
                ]))
            }
            return .json(openMeteoBody(url, value: 1800))
        }

        let result = await makeRouter(http, cache).routeLeg(from: start, to: end)

        #expect(result.leg.isStraight)
        #expect(result.provenance.detail == "no direct trail, straight line")
        // Not stale: the router answered correctly, we chose not to use it.
        #expect(result.provenance.isStale == false)
        #expect(result.leg.coordinates.allSatisfy { $0.elevation == 1800 })
    }

    @Test func `a dead router degrades to a straight line marked stale`() async {
        let (cache, dir) = tempCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let http = FakeHTTP { url in
            url.host == "brouter.de" ? .failure : .json(openMeteoBody(url, value: 1900))
        }

        let result = await makeRouter(http, cache).routeLeg(from: start, to: end)

        #expect(result.leg.isStraight)
        #expect(result.provenance.detail == "unreachable, straight line")
        #expect(result.provenance.isStale)
        #expect(result.leg.coordinates.count >= 2)
    }

    @Test func `empty geometry counts as a failure, not an empty route`() async {
        let (cache, dir) = tempCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let http = FakeHTTP { url in
            if url.host == "brouter.de" { return .json(#"{"features":[]}"#) }
            return .json(openMeteoBody(url, value: 1700))
        }

        let result = await makeRouter(http, cache).routeLeg(from: start, to: end)
        #expect(result.leg.isStraight)
        #expect(result.leg.coordinates.count >= 2)
    }

    // Over a few metres the indirectness ratio is meaningless — a trail that
    // switchbacks twice in 30 m is still the right answer.
    @Test func `very short legs keep the snapped path however indirect`() async {
        let (cache, dir) = tempCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = Coordinate(longitude: -105.28110, latitude: 39.99920)
        let b = Coordinate(longitude: -105.28130, latitude: 39.99925)  // ~18 m

        let http = FakeHTTP { _ in
            .json(brouterBody([
                (-105.28110, 39.99920, 1760),
                (-105.28200, 39.99960, 1762),  // a long way round for 18 m
                (-105.28130, 39.99925, 1761),
            ]))
        }

        let result = await makeRouter(http, cache).routeLeg(from: a, to: b)
        #expect(result.leg.isStraight == false)
        #expect(result.provenance.detail == "snapped to trail")
    }
}

@Suite("Straight-line sampling")
struct StraightSampleTests {

    @Test func `samples land one per hundred metres`() {
        // ~1,728 m apart -> round(17.28) + 1 = 18 samples.
        let samples = Router.straightSamples(from: start, to: end)
        #expect(samples.count == 18)
        #expect(samples.first?.longitude == start.longitude)
        #expect(samples.last?.latitude == end.latitude)
    }

    @Test func `a long off-trail line is capped rather than firing hundreds of lookups`() {
        let denver = Coordinate(longitude: -104.9903, latitude: 39.7392)
        let telluride = Coordinate(longitude: -107.8123, latitude: 37.9375)
        // 316 km would be 3,161 samples uncapped.
        #expect(Router.straightSamples(from: denver, to: telluride).count == 60)
    }

    @Test func `even a zero-length leg yields two endpoints`() {
        #expect(Router.straightSamples(from: start, to: start).count == 2)
    }

    @Test func `samples are evenly spaced along the line`() {
        let samples = Router.straightSamples(from: start, to: end)
        let gaps = zip(samples, samples.dropFirst()).map { $0.distance(to: $1) }
        let first = gaps[0]
        #expect(gaps.allSatisfy { abs($0 - first) < 0.5 })
    }

    @Test func `the request URL carries the hiking-mountain profile`() throws {
        let url = try #require(Router.url(from: start, to: end))
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains { $0.name == "profile" && $0.value == "hiking-mountain" })
        #expect(query.contains { $0.name == "format" && $0.value == "geojson" })
        #expect(query.first { $0.name == "lonlats" }?.value
            == "-105.2811,39.9992|-105.2928,39.9865")
    }
}
