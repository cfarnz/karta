import Foundation

// Geodesy and units.
//
// The web app passed coordinates as [lon, lat, ele?] arrays, which meant every
// call site had to remember that longitude comes first and that index 2 may or
// may not exist. A struct states both once.

public enum Units {
    public static let metersPerMile = 1609.344
    public static let feetPerMeter = 3.28084
    /// Earth radius used by the web app's haversine, kept identical so ported
    /// distances match the JS numbers exactly rather than approximately.
    public static let earthRadiusM = 6_371_000.0
}

public struct Coordinate: Hashable, Sendable, Codable {
    public var longitude: Double
    public var latitude: Double
    /// Metres above sea level. Nil means "not sampled yet" — distinct from 0,
    /// which is a real elevation at sea level.
    public var elevation: Double?

    public init(longitude: Double, latitude: Double, elevation: Double? = nil) {
        self.longitude = longitude
        self.latitude = latitude
        self.elevation = elevation
    }

    /// Drops elevation. Used as a cache key and when a provider is about to
    /// supply a fresh value.
    public var flat: Coordinate {
        Coordinate(longitude: longitude, latitude: latitude)
    }
}

extension Coordinate {
    /// Great-circle distance in metres.
    public func distance(to other: Coordinate) -> Double {
        let dLat = (other.latitude - latitude) * .pi / 180
        let dLon = (other.longitude - longitude) * .pi / 180
        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let s = (sin(dLat / 2) * sin(dLat / 2))
            + cos(lat1) * cos(lat2) * (sin(dLon / 2) * sin(dLon / 2))
        return 2 * Units.earthRadiusM * asin(min(1, sqrt(s)))
    }

    /// Spherical destination point: travel `distanceM` along `bearingDegrees`.
    /// Drives Discover's loop geometry.
    public func offset(bearingDegrees: Double, distanceM: Double) -> Coordinate {
        let br = bearingDegrees * .pi / 180
        let lat1 = latitude * .pi / 180
        let lon1 = longitude * .pi / 180
        let d = distanceM / Units.earthRadiusM

        let lat2 = asin(sin(lat1) * cos(d) + cos(lat1) * sin(d) * cos(br))
        let lon2 = lon1 + atan2(
            sin(br) * sin(d) * cos(lat1),
            cos(d) - sin(lat1) * sin(lat2)
        )
        return Coordinate(longitude: lon2 * 180 / .pi, latitude: lat2 * 180 / .pi)
    }
}

extension Collection<Coordinate> {
    /// Summed great-circle length in metres.
    public var trackLengthM: Double {
        guard count > 1 else { return 0 }
        return zip(self, dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
    }
}
