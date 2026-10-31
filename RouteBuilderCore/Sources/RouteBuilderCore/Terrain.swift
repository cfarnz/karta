import Foundation

/// Slope and aspect at a single point, from a 3x3 grid of sampled elevations.
///
/// The overlay computes the same quantities per pixel over a DEM tile. This
/// path exists because the card wants one accurate answer rather than a whole
/// viewport: the resolver picks the best provider for the point (1 m 3DEP
/// inside the US, 90 m Open-Meteo outside) and the sample spacing follows it.

public struct TerrainSample: Sendable, Equatable {
    public var elevationFt: Double
    public var slopeDegrees: Double
    /// Nil on flat ground, which has no meaningful aspect.
    public var aspectDegrees: Double?
    public var demProvider: String
    public var demResolutionM: Double
    /// How far apart the 3x3 samples were taken.
    public var spacingM: Double

    public init(elevationFt: Double, slopeDegrees: Double, aspectDegrees: Double?,
                demProvider: String, demResolutionM: Double, spacingM: Double) {
        self.elevationFt = elevationFt
        self.slopeDegrees = slopeDegrees
        self.aspectDegrees = aspectDegrees
        self.demProvider = demProvider
        self.demResolutionM = demResolutionM
        self.spacingM = spacingM
    }
}

public enum TerrainMath {
    /// Degrees of latitude to metres. The web app's constant, kept so the
    /// sample grid lands on the same ground.
    public static let metersPerDegreeLatitude = 111_320.0

    /// Below this the aspect is noise, so the card says "flat" instead of
    /// pointing confidently at a direction derived from DEM jitter.
    public static let flatBelowDegrees = 1.0

    /// The 3x3 sample points around a centre, rows north to south and
    /// columns west to east — the order Horn's method expects.
    public static func sampleGrid(around point: Coordinate, spacingM: Double) -> [Coordinate] {
        let metersPerDegreeLongitude =
            metersPerDegreeLatitude * cos(point.latitude * .pi / 180)
        let dLat = spacingM / metersPerDegreeLatitude
        let dLon = spacingM / metersPerDegreeLongitude

        var grid: [Coordinate] = []
        grid.reserveCapacity(9)
        for row in -1...1 {
            for column in -1...1 {
                grid.append(Coordinate(
                    longitude: point.longitude + Double(column) * dLon,
                    latitude: point.latitude - Double(row) * dLat))
            }
        }
        return grid
    }

    /// Horn's method over a 3x3 window, as used by ESRI and by the overlay.
    ///
    /// `elevations` is row-major, north-west first — the order `sampleGrid`
    /// produces.
    public static func gradients(
        elevations z: [Double], spacingM: Double
    ) -> (dzdx: Double, dzdy: Double)? {
        guard z.count == 9, spacingM > 0 else { return nil }
        let (a, b, c) = (z[0], z[1], z[2])
        let (d, f) = (z[3], z[5])
        let (g, h, i) = (z[6], z[7], z[8])

        return (
            dzdx: (c + 2 * f + i - (a + 2 * d + g)) / (8 * spacingM),
            dzdy: (g + 2 * h + i - (a + 2 * b + c)) / (8 * spacingM)
        )
    }

    public static func slopeDegrees(dzdx: Double, dzdy: Double) -> Double {
        atan((dzdx * dzdx + dzdy * dzdy).squareRoot()) * 180 / .pi
    }

    /// Sixteen-point compass. Used for aspect and for wind direction.
    public static let compassPoints = [
        "N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
        "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW",
    ]

    public static func compass(_ degrees: Double) -> String {
        // Negative bearings would land on a negative index, and wind
        // directions arrive straight from a provider.
        let index = Int((degrees / 22.5).rounded())
        return compassPoints[((index % 16) + 16) % 16]
    }
}

/// Where a slope angle sits relative to avalanche terrain.
///
/// Observational, not advice: most slab avalanches release between 30 and 45
/// degrees, so that band is worth noticing on a card that also shows a
/// danger rating.
public enum SlopeBand: String, Sendable, Equatable {
    case low
    case avalanche
    case steep

    public static func of(_ degrees: Double) -> SlopeBand {
        if degrees >= 30 && degrees <= 45 { return .avalanche }
        return degrees > 45 ? .steep : .low
    }

    public var note: String? {
        switch self {
        case .avalanche: "In the 30–45° band where most slab avalanches release."
        case .steep, .low: nil
        }
    }
}
