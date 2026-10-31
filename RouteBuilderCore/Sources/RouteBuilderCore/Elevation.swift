import Foundation

/// Elevation providers, and the resolver that picks between them.
///
/// Which provider answers depends on where the point is and what the caller
/// needs:
///
///   USGS 3DEP    1 m, US only, one point per request  -> summary cards
///   Open-Meteo  ~90 m, global, 100 points per request -> routes and Discover
///
/// A route samples thousands of points and needs them fast. A summary card
/// samples nine and needs them right. Same data, different answer.
public struct ElevationProvider: Sendable, Equatable {
    public var name: String
    /// Source resolution in metres.
    public var resolutionM: Double
    /// How far apart to sample when deriving slope from this provider.
    /// Sampling much tighter than the source invents detail that is not there;
    /// much wider smooths real terrain away.
    public var spacingM: Double

    public static let usgs = ElevationProvider(name: "USGS 3DEP", resolutionM: 1, spacingM: 30)
    public static let openMeteo = ElevationProvider(name: "Open-Meteo", resolutionM: 90, spacingM: 90)
}

public struct ElevationResult: Sendable {
    /// Metres, in the same order as the requested points.
    public var values: [Double]
    public var provenance: ProvenanceRecord
    public var resolutionM: Double
}

public actor ElevationService {
    private let http: HTTPFetching
    private let cache: ProviderCache

    private static let openMeteoBase = "https://api.open-meteo.com/v1/elevation"
    private static let epqsBase = "https://epqs.nationalmap.gov/v1/json"
    /// Open-Meteo's per-request coordinate limit.
    private static let openMeteoBatch = 100
    /// EPQS answers one point per call, so these go out in parallel.
    private static let usgsConcurrency = 6

    public init(http: HTTPFetching, cache: ProviderCache) {
        self.http = http
        self.cache = cache
    }

    // ---------- coverage ----------

    /// 3DEP coverage as bounding boxes: west, south, east, north.
    /// The one place geography lives — everything else asks the resolver
    /// rather than testing coordinates itself.
    static let usgsBounds: [(w: Double, s: Double, e: Double, n: Double)] = [
        (-125.0, 24.0, -66.5, 49.5),   // contiguous US
        (-170.0, 51.0, -129.0, 72.0),  // Alaska
        (-161.0, 18.0, -154.0, 23.0),  // Hawaii
    ]

    static func isInUSGS(_ coordinate: Coordinate) -> Bool {
        usgsBounds.contains { box in
            coordinate.longitude >= box.w && coordinate.longitude <= box.e
                && coordinate.latitude >= box.s && coordinate.latitude <= box.n
        }
    }

    public static func provider(for coordinate: Coordinate) -> ElevationProvider {
        isInUSGS(coordinate) ? .usgs : .openMeteo
    }

    // ---------- cache keys ----------
    //
    // Namespaced per provider: a 90 m answer and a 1 m answer for the same
    // ground are different numbers and must not satisfy each other's lookups.
    //
    // Coarse rounds to ~11 m, well under Open-Meteo's source resolution.
    // Fine rounds to ~1 m to match 3DEP.

    /// JavaScript's `Math.round` breaks ties toward positive infinity;
    /// Swift's `rounded()` breaks them away from zero. At western longitudes
    /// every negative half-value would land in a different grid cell, so the
    /// JS behaviour is reproduced exactly here. Mismatched keys would only
    /// cost a cache miss, but a cache that disagrees with itself across a
    /// rewrite is not worth debugging later.
    static func jsRound(_ value: Double) -> Int {
        Int((value + 0.5).rounded(.down))
    }

    static func coarseKey(_ coordinate: Coordinate) -> String {
        "\(jsRound(coordinate.longitude * 1e4)),\(jsRound(coordinate.latitude * 1e4))"
    }

    static func fineKey(_ coordinate: Coordinate) -> String {
        "u:\(jsRound(coordinate.longitude * 1e5)),\(jsRound(coordinate.latitude * 1e5))"
    }

    // ---------- fetchers ----------

    private struct OpenMeteoResponse: Decodable {
        var elevation: [Double]?
    }

    private func fetchOpenMeteo(_ coordinates: [Coordinate]) async throws -> [Double] {
        let lats = coordinates.map { String(format: "%.5f", $0.latitude) }.joined(separator: ",")
        let lons = coordinates.map { String(format: "%.5f", $0.longitude) }.joined(separator: ",")
        guard let url = URL(string: "\(Self.openMeteoBase)?latitude=\(lats)&longitude=\(lons)") else {
            throw HTTPError(statusCode: -1, source: "Open-Meteo")
        }
        let data = try await http.data(from: url)
        return try JSONDecoder().decode(OpenMeteoResponse.self, from: data).elevation ?? []
    }

    private struct EPQSResponse: Decodable {
        var value: String?
    }

    private func fetchUSGS(_ coordinate: Coordinate) async throws -> Double {
        let x = String(format: "%.6f", coordinate.longitude)
        let y = String(format: "%.6f", coordinate.latitude)
        guard let url = URL(string:
            "\(Self.epqsBase)?x=\(x)&y=\(y)&units=Meters&wkid=4326&includeDate=false")
        else { throw HTTPError(statusCode: -1, source: "USGS") }

        let data = try await http.data(from: url)
        guard let raw = try JSONDecoder().decode(EPQSResponse.self, from: data).value,
              let value = Double(raw),
              value.isFinite,
              // EPQS reports no-data as a large negative sentinel, not an error.
              value > -1000
        else { throw HTTPError(statusCode: 204, source: "USGS") }
        return value
    }

    // ---------- bulk path ----------

    /// Elevations in metres for a list of coordinates, same order.
    ///
    /// Terrain does not change, so every point ever looked up stays reusable.
    /// Missing points resolve to 0 rather than throwing: a route with one bad
    /// sample is still a usable route.
    public func elevations(for coordinates: [Coordinate]) async -> ElevationResult {
        guard !coordinates.isEmpty else {
            return ElevationResult(
                values: [],
                provenance: .init(dataset: "Elevation", provider: "Open-Meteo", detail: "no points"),
                resolutionM: ElevationProvider.openMeteo.resolutionM
            )
        }

        let keys = coordinates.map(Self.coarseKey)
        let known = await cache.points(keys)

        // Dedupe by grid cell: a dragged waypoint re-samples ground the last
        // drag already paid for.
        //
        // Deliberately an ordered array rather than a dictionary. Pairing
        // request order with response order is correct either way, but the web
        // app used an insertion-ordered Map, and keeping requests in the
        // caller's order means a given route always produces the same sequence
        // of calls — the difference between a reproducible bug report and a
        // heisenbug.
        var missing: [(key: String, coordinate: Coordinate)] = []
        var seen = Set<String>()
        for (key, coordinate) in zip(keys, coordinates) where known[key] == nil {
            if seen.insert(key).inserted {
                missing.append((key, coordinate))
            }
        }

        var fetchedValues: [String: Double] = [:]
        var anyFailure = false

        for chunk in missing.chunked(into: Self.openMeteoBatch) {
            do {
                let values = try await fetchOpenMeteo(chunk.map(\.coordinate))
                for (index, entry) in chunk.enumerated() where index < values.count {
                    fetchedValues[entry.key] = values[index]
                }
            } catch {
                anyFailure = true  // partial results are fine; gaps fall back to 0
            }
        }

        if !fetchedValues.isEmpty {
            await cache.setPoints(fetchedValues)
        }

        let values = keys.map { known[$0] ?? fetchedValues[$0] ?? 0 }

        return ElevationResult(
            values: values,
            provenance: .init(
                dataset: "Elevation",
                provider: "Open-Meteo",
                detail: "\(coordinates.count - missing.count) cached · \(fetchedValues.count) fetched",
                isStale: anyFailure,
                fromCache: missing.isEmpty
            ),
            resolutionM: ElevationProvider.openMeteo.resolutionM
        )
    }

    // ---------- precision path ----------

    /// Used where accuracy matters more than volume.
    ///
    /// Falls back to the bulk provider per point, so a 3DEP outage degrades
    /// the numbers rather than emptying the card.
    public func preciseElevations(for coordinates: [Coordinate]) async -> ElevationResult {
        guard let first = coordinates.first else {
            return await elevations(for: coordinates)
        }
        guard Self.provider(for: first) == .usgs else {
            return await elevations(for: coordinates)
        }

        let keys = coordinates.map(Self.fineKey)
        let known = await cache.points(keys)

        var resolved: [String: Double] = known
        let missingIndices = keys.indices.filter { known[keys[$0]] == nil }

        if !missingIndices.isEmpty {
            let fetched = await withTaskGroup(
                of: (Int, Double?).self,
                returning: [Int: Double].self
            ) { group in
                var out: [Int: Double] = [:]
                var next = 0

                // Bounded fan-out: start the cap, then add one as each lands.
                // An unbounded group here would open one socket per sampled
                // point and get the app rate-limited off EPQS.
                func addNext() {
                    guard next < missingIndices.count else { return }
                    let index = missingIndices[next]
                    let coordinate = coordinates[index]
                    next += 1
                    group.addTask { [self] in
                        (index, try? await fetchUSGS(coordinate))
                    }
                }

                for _ in 0..<min(Self.usgsConcurrency, missingIndices.count) { addNext() }

                while let (index, value) = await group.next() {
                    if let value { out[index] = value }
                    addNext()
                }
                return out
            }

            var fresh: [String: Double] = [:]
            for (index, value) in fetched {
                resolved[keys[index]] = value
                fresh[keys[index]] = value
            }
            if !fresh.isEmpty { await cache.setPoints(fresh) }
        }

        // Anything 3DEP could not answer falls back to the coarse provider.
        let gaps = keys.indices.filter { resolved[keys[$0]] == nil }
        var values = keys.map { resolved[$0] ?? 0 }
        let degraded = !gaps.isEmpty

        if degraded {
            let fill = await elevations(for: gaps.map { coordinates[$0] })
            for (offset, index) in gaps.enumerated() where offset < fill.values.count {
                values[index] = fill.values[offset]
            }
        }

        let detail = degraded
            ? "\(coordinates.count - gaps.count) at 1 m · \(gaps.count) fell back"
            : "\(coordinates.count - missingIndices.count) cached · \(missingIndices.count) fetched · 1 m"

        return ElevationResult(
            values: values,
            provenance: .init(
                dataset: "Elevation",
                provider: degraded ? "USGS 3DEP with Open-Meteo fallback" : "USGS 3DEP",
                detail: detail,
                isStale: degraded,
                fromCache: missingIndices.isEmpty
            ),
            resolutionM: degraded ? ElevationProvider.openMeteo.resolutionM : 1
        )
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
