import Foundation

/// Routing adapter: the public BRouter API, with a straight-line fallback.
public actor Router {
    private let http: HTTPFetching
    private let elevation: ElevationService

    private static let base = "https://brouter.de/brouter"
    private static let profile = "hiking-mountain"
    /// A snapped path more than this many times the straight-line distance
    /// means the router wandered off to find a trail that is not really
    /// "between" the points.
    static let indirectRatio = 3.0
    /// Below this, a snap is never rejected for being indirect — over a few
    /// metres the ratio is meaningless.
    static let minRatioDistanceM = 50.0
    /// One sample per ~100 m along a straight leg, clamped so a long off-trail
    /// line does not fire off hundreds of elevation lookups.
    static let maxStraightSamples = 60

    public init(http: HTTPFetching, elevation: ElevationService) {
        self.http = http
        self.elevation = elevation
    }

    public struct RoutedLeg: Sendable {
        public var leg: Leg
        public var provenance: ProvenanceRecord
    }

    // ---------- BRouter ----------

    private struct GeoJSON: Decodable {
        struct Feature: Decodable {
            struct Geometry: Decodable { var coordinates: [[Double]] }
            var geometry: Geometry
        }
        var features: [Feature]
    }

    static func url(from: Coordinate, to: Coordinate) -> URL? {
        let pair = "\(from.longitude),\(from.latitude)|\(to.longitude),\(to.latitude)"
        var components = URLComponents(string: base)
        components?.queryItems = [
            .init(name: "lonlats", value: pair),
            .init(name: "profile", value: profile),
            .init(name: "alternativeidx", value: "0"),
            .init(name: "format", value: "geojson"),
        ]
        return components?.url
    }

    private func snap(from: Coordinate, to: Coordinate) async throws -> [Coordinate] {
        guard let url = Self.url(from: from, to: to) else {
            throw HTTPError(statusCode: -1, source: "BRouter")
        }
        let data = try await http.data(from: url)
        let decoded = try JSONDecoder().decode(GeoJSON.self, from: data)

        let raw = decoded.features.first?.geometry.coordinates ?? []
        guard raw.count >= 2 else {
            throw HTTPError(statusCode: 204, source: "BRouter")  // empty geometry
        }

        return raw.compactMap { pair in
            guard pair.count >= 2 else { return nil }
            return Coordinate(
                longitude: pair[0],
                latitude: pair[1],
                elevation: pair.count > 2 ? pair[2] : nil
            )
        }
    }

    // ---------- straight-line fallback ----------

    /// Interpolated points along a straight segment.
    static func straightSamples(from: Coordinate, to: Coordinate) -> [Coordinate] {
        let distanceM = from.distance(to: to)
        let n = min(maxStraightSamples, max(2, Int((distanceM / 100).rounded()) + 1))
        return (0..<n).map { index in
            let t = Double(index) / Double(n - 1)
            return Coordinate(
                longitude: from.longitude + (to.longitude - from.longitude) * t,
                latitude: from.latitude + (to.latitude - from.latitude) * t
            )
        }
    }

    /// Sample elevations for a straight segment so gain stats and the profile
    /// stay honest off-trail. Goes through the cached provider, so re-dragging
    /// a waypoint over ground already sampled costs no requests.
    private func elevatedStraight(from: Coordinate, to: Coordinate) async -> [Coordinate] {
        let samples = Self.straightSamples(from: from, to: to)
        let result = await elevation.elevations(for: samples)
        return zip(samples, result.values).map { sample, value in
            Coordinate(longitude: sample.longitude, latitude: sample.latitude, elevation: value)
        }
    }

    // ---------- the leg ----------

    /// Route one leg, preferring a real trail.
    ///
    /// Three outcomes, each reported distinctly so the provenance panel can
    /// tell "this follows a trail" from "there is no trail here" from "the
    /// router is down" — which look identical on the map but mean very
    /// different things on the ground.
    public func routeLeg(from: Coordinate, to: Coordinate) async -> RoutedLeg {
        let straightM = from.distance(to: to)

        do {
            let coordinates = try await snap(from: from, to: to)
            let snappedM = coordinates.trackLengthM

            if snappedM <= straightM * Self.indirectRatio || straightM < Self.minRatioDistanceM {
                return RoutedLeg(
                    leg: Leg(coordinates: coordinates, isStraight: false),
                    provenance: .init(dataset: "Routing", provider: "BRouter",
                                      detail: "snapped to trail")
                )
            }

            return RoutedLeg(
                leg: Leg(coordinates: await elevatedStraight(from: from, to: to), isStraight: true),
                provenance: .init(dataset: "Routing", provider: "BRouter",
                                  detail: "no direct trail, straight line")
            )
        } catch {
            return RoutedLeg(
                leg: Leg(coordinates: await elevatedStraight(from: from, to: to), isStraight: true),
                provenance: .init(dataset: "Routing", provider: "BRouter",
                                  detail: "unreachable, straight line", isStale: true)
            )
        }
    }
}
