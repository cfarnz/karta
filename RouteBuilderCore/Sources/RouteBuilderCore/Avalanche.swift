import Foundation

/// CAIC forecast zones, served through the National Avalanche Center API.
///
/// The whole state's zone polygons arrive in one response, so it is fetched
/// once every three hours and the containing zone found locally. That also
/// means a zone lookup still works with no signal, which is the point.

public struct AvalancheZone: Sendable, Equatable {
    public var zone: String?
    public var level: Int?
    public var danger: String?
    public var travelAdvice: String?
    /// CAIC's own colour for the danger level, when it supplies one.
    public var color: String?
    public var warningTitle: String?
    /// CAIC forecasts run roughly November through May. Out of season the
    /// API returns one merged zone rated "no rating" rather than nothing, so
    /// a blank card in July is correct, not broken.
    public var isOffSeason: Bool
}

public enum GeoPolygon {
    /// Ray casting. Matches the web app's implementation exactly, including
    /// its handling of points on a vertex, so zone edges resolve the same way.
    public static func contains(_ point: Coordinate, ring: [[Double]]) -> Bool {
        guard ring.count > 2 else { return false }
        let x = point.longitude
        let y = point.latitude

        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            guard ring[i].count >= 2, ring[j].count >= 2 else { j = i; continue }
            let (xi, yi) = (ring[i][0], ring[i][1])
            let (xj, yj) = (ring[j][0], ring[j][1])
            if (yi > y) != (yj > y), x < (xj - xi) * (y - yi) / (yj - yi) + xi {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// A polygon's first ring is its outer boundary; the rest are holes.
    public static func contains(_ point: Coordinate, polygon: [[[Double]]]) -> Bool {
        guard let outer = polygon.first, contains(point, ring: outer) else { return false }
        return !polygon.dropFirst().contains { contains(point, ring: $0) }
    }

    public static func contains(_ point: Coordinate, geometry: CAICGeometry) -> Bool {
        switch geometry.kind {
        case .polygon(let polygon): contains(point, polygon: polygon)
        case .multiPolygon(let polygons): polygons.contains { contains(point, polygon: $0) }
        case .unsupported: false
        }
    }
}

// ---------- wire format ----------

/// GeoJSON geometry, decoded only as far as the zone lookup needs.
public struct CAICGeometry: Codable, Sendable {
    public enum Kind: Sendable {
        case polygon([[[Double]]])
        case multiPolygon([[[[Double]]]])
        case unsupported
    }
    public var kind: Kind

    private enum CodingKeys: String, CodingKey { case type, coordinates }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decodeIfPresent(String.self, forKey: .type) {
        case "Polygon":
            kind = .polygon(
                (try? container.decode([[[Double]]].self, forKey: .coordinates)) ?? [])
        case "MultiPolygon":
            kind = .multiPolygon(
                (try? container.decode([[[[Double]]]].self, forKey: .coordinates)) ?? [])
        default:
            kind = .unsupported
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch kind {
        case .polygon(let polygon):
            try container.encode("Polygon", forKey: .type)
            try container.encode(polygon, forKey: .coordinates)
        case .multiPolygon(let polygons):
            try container.encode("MultiPolygon", forKey: .type)
            try container.encode(polygons, forKey: .coordinates)
        case .unsupported:
            try container.encode("Unsupported", forKey: .type)
        }
    }
}

public struct CAICMapLayer: Codable, Sendable {
    public struct Feature: Codable, Sendable {
        public struct Properties: Codable, Sendable {
            public struct Warning: Codable, Sendable {
                public var product: String?
                public var title: String?
            }
            public var name: String?
            public var danger_level: Int?
            public var danger: String?
            public var travel_advice: String?
            public var color: String?
            public var warning: Warning?
        }
        public var geometry: CAICGeometry?
        public var properties: Properties?
    }
    public var features: [Feature]?
}

extension CAICMapLayer.Feature.Properties {
    /// Out of season CAIC returns a single merged zone rated "no rating"
    /// rather than dropping the feed, and -1 is its sentinel danger level.
    var isOffSeason: Bool {
        danger_level == -1 || danger?.lowercased() == "no rating"
    }

    func asZone() -> AvalancheZone {
        AvalancheZone(
            zone: name,
            level: danger_level,
            danger: danger,
            travelAdvice: travel_advice,
            color: color,
            warningTitle: warning?.product != nil ? warning?.title : nil,
            isOffSeason: isOffSeason
        )
    }
}
