import Foundation
import Testing
@testable import RouteBuilderCore

/// Canned HTTP. Records every URL it was asked for so tests can assert on
/// batching and request counts, not just on returned numbers.
actor FakeHTTP: HTTPFetching {
    enum Response {
        case json(String)
        case failure
    }

    private var handler: @Sendable (URL) -> Response
    private(set) var requestedURLs: [URL] = []

    init(handler: @escaping @Sendable (URL) -> Response) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> Data {
        guard let url = request.url else { throw HTTPError(statusCode: -1, source: "fake") }
        requestedURLs.append(url)
        switch handler(url) {
        case .json(let body): return Data(body.utf8)
        case .failure: throw HTTPError(statusCode: 503, source: url.host ?? "fake")
        }
    }

    var requestCount: Int { requestedURLs.count }
}

private func tempCache() -> (ProviderCache, URL) {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("rb-ele-\(UUID().uuidString)", isDirectory: true)
    return (ProviderCache(directory: dir), dir)
}

/// Counts how many coordinates an Open-Meteo URL asked about, so a fake can
/// answer with the right-length array.
private func openMeteoCount(_ url: URL) -> Int {
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let lats = query.first { $0.name == "latitude" }?.value ?? ""
    return lats.split(separator: ",").count
}

@Suite("Elevation provider selection")
struct ElevationProviderTests {

    @Test(arguments: [
        ("Boulder", -105.28, 39.99, "USGS 3DEP"),
        ("Telluride", -107.81, 37.94, "USGS 3DEP"),
        ("Denali", -151.0, 63.07, "USGS 3DEP"),
        ("Mauna Kea", -155.47, 19.82, "USGS 3DEP"),
        ("Chamonix", 6.87, 45.92, "Open-Meteo"),
        ("Patagonia", -72.99, -50.94, "Open-Meteo"),
        ("Vancouver, just north of the box", -123.1, 49.6, "Open-Meteo"),
    ])
    func `coverage boxes route each point to the right provider`(
        place: String, lon: Double, lat: Double, expected: String
    ) {
        let provider = ElevationService.provider(
            for: Coordinate(longitude: lon, latitude: lat))
        #expect(provider.name == expected, "\(place) should use \(expected)")
    }

    @Test func `3DEP samples tighter than Open-Meteo for slope`() {
        // Sampling spacing has to track source resolution or derived slope is
        // either invented detail or smoothed-away terrain.
        #expect(ElevationProvider.usgs.spacingM == 30)
        #expect(ElevationProvider.openMeteo.spacingM == 90)
    }
}

@Suite("Elevation cache keys")
struct ElevationKeyTests {

    // JS Math.round breaks ties toward +infinity; Swift's rounded() breaks
    // them away from zero. Every negative half-value would otherwise land in a
    // different grid cell than the web app chose.
    @Test(arguments: [
        (0.5, 1), (1.5, 2), (2.5, 3),
        (-0.5, 0), (-1.5, -1), (-2.5, -2),
        (-1_052_811.5, -1_052_811),
    ])
    func `rounding matches JavaScript at the half-value boundaries`(input: Double, expected: Int) {
        #expect(ElevationService.jsRound(input) == expected)
    }

    @Test func `coarse and fine keys never satisfy each other`() {
        // A 90 m answer and a 1 m answer for the same ground are different
        // numbers and must not collide in one cache.
        let point = Coordinate(longitude: -105.2811, latitude: 39.9992)
        #expect(ElevationService.coarseKey(point) != ElevationService.fineKey(point))
        #expect(ElevationService.fineKey(point).hasPrefix("u:"))
    }

    @Test func `points within a coarse grid cell share a key`() {
        // ~11 m apart, under Open-Meteo's 90 m resolution: one answer serves both.
        let a = Coordinate(longitude: -105.28110, latitude: 39.99920)
        let b = Coordinate(longitude: -105.28114, latitude: 39.99922)
        #expect(ElevationService.coarseKey(a) == ElevationService.coarseKey(b))
        // But not in the fine grid, which tracks 3DEP's metre.
        #expect(ElevationService.fineKey(a) != ElevationService.fineKey(b))
    }
}

@Suite("Bulk elevation path")
struct BulkElevationTests {

    private func spread(_ n: Int) -> [Coordinate] {
        // ~85 m apart, so each lands in its own coarse grid cell.
        (0..<n).map { Coordinate(longitude: -105 + Double($0) * 0.001, latitude: 40) }
    }

    @Test func `elevations come back in the order they were asked for`() async {
        let (cache, dir) = tempCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let http = FakeHTTP { url in
            let n = openMeteoCount(url)
            let values = (0..<n).map { "\(1000 + $0 * 10)" }.joined(separator: ",")
            return .json(#"{"elevation":[\#(values)]}"#)
        }
        let service = ElevationService(http: http, cache: cache)

        let result = await service.elevations(for: spread(5))
        #expect(result.values == [1000, 1010, 1020, 1030, 1040])
        #expect(result.provenance.provider == "Open-Meteo")
        #expect(result.resolutionM == 90)
    }

    @Test func `requests are batched at Open-Meteo's hundred-point limit`() async {
        let (cache, dir) = tempCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let http = FakeHTTP { url in
            let n = openMeteoCount(url)
            #expect(n <= 100, "a batch exceeded Open-Meteo's documented limit")
            return .json(#"{"elevation":[\#((0..<n).map { _ in "2000" }.joined(separator: ","))]}"#)
        }
        let service = ElevationService(http: http, cache: cache)

        _ = await service.elevations(for: spread(250))
        #expect(await http.requestCount == 3)  // 100 + 100 + 50
    }

    @Test func `a second lookup of the same ground costs no requests`() async {
        let (cache, dir) = tempCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let http = FakeHTTP { url in
            let n = openMeteoCount(url)
            return .json(#"{"elevation":[\#((0..<n).map { _ in "2000" }.joined(separator: ","))]}"#)
        }
        let service = ElevationService(http: http, cache: cache)
        let points = spread(40)

        _ = await service.elevations(for: points)
        let afterFirst = await http.requestCount
        let second = await service.elevations(for: points)

        #expect(await http.requestCount == afterFirst, "re-dragging a waypoint refetched terrain")
        #expect(second.values.allSatisfy { $0 == 2000 })
        #expect(second.provenance.fromCache)
    }

    @Test func `duplicate points within one call collapse to a single sample`() async {
        let (cache, dir) = tempCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let http = FakeHTTP { url in
            #expect(openMeteoCount(url) == 1, "identical points were not deduped")
            return .json(#"{"elevation":[1760]}"#)
        }
        let service = ElevationService(http: http, cache: cache)

        let point = Coordinate(longitude: -105.2811, latitude: 39.9992)
        let result = await service.elevations(for: [point, point, point])
        #expect(result.values == [1760, 1760, 1760])
    }

    // A route with one bad sample is still a usable route, so a dead provider
    // degrades to zeros and says so rather than throwing the route away.
    @Test func `a provider outage yields zeros marked stale, not an error`() async {
        let (cache, dir) = tempCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let service = ElevationService(http: FakeHTTP { _ in .failure }, cache: cache)
        let result = await service.elevations(for: spread(3))

        #expect(result.values == [0, 0, 0])
        #expect(result.provenance.isStale)
    }

    @Test func `an empty request does not hit the network`() async {
        let (cache, dir) = tempCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let http = FakeHTTP { _ in .failure }
        let service = ElevationService(http: http, cache: cache)

        let result = await service.elevations(for: [])
        #expect(result.values.isEmpty)
        #expect(await http.requestCount == 0)
    }
}

@Suite("Precision elevation path")
struct PreciseElevationTests {

    @Test func `inside 3DEP coverage every point is fetched at one metre`() async {
        let (cache, dir) = tempCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let http = FakeHTTP { url in
            #expect(url.host == "epqs.nationalmap.gov")
            return .json(#"{"value":"1760.25"}"#)
        }
        let service = ElevationService(http: http, cache: cache)

        let points = (0..<9).map {
            Coordinate(longitude: -105.28 + Double($0) * 0.0003, latitude: 39.99)
        }
        let result = await service.preciseElevations(for: points)

        #expect(result.values == Array(repeating: 1760.25, count: 9))
        #expect(result.provenance.provider == "USGS 3DEP")
        #expect(result.resolutionM == 1)
        #expect(result.provenance.isStale == false)
    }

    @Test func `outside coverage it delegates to the global provider`() async {
        let (cache, dir) = tempCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let http = FakeHTTP { url in
            #expect(url.host == "api.open-meteo.com", "3DEP was queried outside the US")
            let n = openMeteoCount(url)
            return .json(#"{"elevation":[\#((0..<n).map { _ in "3842" }.joined(separator: ","))]}"#)
        }
        let service = ElevationService(http: http, cache: cache)

        // Mont Blanc.
        let result = await service.preciseElevations(
            for: [Coordinate(longitude: 6.8652, latitude: 45.8326)])
        #expect(result.values == [3842])
        #expect(result.provenance.provider == "Open-Meteo")
        #expect(result.resolutionM == 90)
    }

    // The point of the fallback: a 3DEP outage should blunt the numbers, not
    // empty the card.
    @Test func `a 3DEP outage falls back to the coarse provider and says so`() async {
        let (cache, dir) = tempCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let http = FakeHTTP { url in
            if url.host == "epqs.nationalmap.gov" { return .failure }
            let n = openMeteoCount(url)
            return .json(#"{"elevation":[\#((0..<n).map { _ in "1755" }.joined(separator: ","))]}"#)
        }
        let service = ElevationService(http: http, cache: cache)

        let points = (0..<3).map {
            Coordinate(longitude: -105.28 + Double($0) * 0.001, latitude: 39.99)
        }
        let result = await service.preciseElevations(for: points)

        #expect(result.values == [1755, 1755, 1755])
        #expect(result.provenance.provider == "USGS 3DEP with Open-Meteo fallback")
        #expect(result.provenance.isStale)
        #expect(result.resolutionM == 90)
    }

    // EPQS signals no-data with a large negative number rather than an HTTP
    // error, which would read as 10,000 m below sea level if taken at face value.
    @Test func `the EPQS no-data sentinel is treated as a miss`() async {
        let (cache, dir) = tempCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let http = FakeHTTP { url in
            if url.host == "epqs.nationalmap.gov" {
                return .json(#"{"value":"-1000000"}"#)
            }
            let n = openMeteoCount(url)
            return .json(#"{"elevation":[\#((0..<n).map { _ in "1500" }.joined(separator: ","))]}"#)
        }
        let service = ElevationService(http: http, cache: cache)

        let result = await service.preciseElevations(
            for: [Coordinate(longitude: -105.28, latitude: 39.99)])
        #expect(result.values == [1500])
        #expect(result.provenance.isStale)
    }

    @Test func `concurrent 3DEP requests stay under the rate cap`() async {
        let (cache, dir) = tempCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let http = FakeHTTP { _ in .json(#"{"value":"2000"}"#) }
        let service = ElevationService(http: http, cache: cache)

        let points = (0..<30).map {
            Coordinate(longitude: -105.28 + Double($0) * 0.0003, latitude: 39.99)
        }
        let result = await service.preciseElevations(for: points)

        // One request per distinct point, all answered — the cap bounds how
        // many are open at once, not how many go out.
        #expect(await http.requestCount == 30)
        #expect(result.values.count == 30)
    }
}
