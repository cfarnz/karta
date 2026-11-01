import Foundation

/// A routed segment between two consecutive waypoints.
public struct Leg: Sendable, Codable, Hashable {
    public var coordinates: [Coordinate]
    /// True when the router could not find a trail and we fell back to a
    /// straight line with sampled elevations.
    public var isStraight: Bool

    public init(coordinates: [Coordinate], isStraight: Bool) {
        self.coordinates = coordinates
        self.isStraight = isStraight
    }
}

public struct RouteStats: Equatable, Sendable {
    public var distanceMiles: Double
    public var gainFeet: Double

    public static let zero = RouteStats(distanceMiles: 0, gainFeet: 0)
}

/// The route as a value: waypoints, the legs between them, and nothing else.
///
/// Undo in the web app serialised this to JSON on every mutation. Here value
/// semantics do the same job for free — pushing a copy onto a stack *is* the
/// snapshot, so there is one code path instead of a serialise/parse pair that
/// could drift.
public struct RouteState: Sendable, Codable, Equatable {
    public var waypoints: [Coordinate] = []
    /// Parallel to the gaps between waypoints. Nil marks a leg awaiting a
    /// rebuild after a waypoint was removed from the middle.
    public var legs: [Leg?] = []

    public init(waypoints: [Coordinate] = [], legs: [Leg?] = []) {
        self.waypoints = waypoints
        self.legs = legs
    }

    public var isEmpty: Bool { waypoints.isEmpty }

    /// Every leg stitched into one continuous track. Legs share their joint
    /// points, so each leg after the first contributes all but its first
    /// coordinate.
    public var track: [Coordinate] {
        var out: [Coordinate] = []
        for leg in legs.compacted() {
            out.append(contentsOf: out.isEmpty ? leg.coordinates[...] : leg.coordinates.dropFirst())
        }
        return out
    }

    public var stats: RouteStats { Self.stats(for: track) }

    /// Distance and cumulative gain.
    ///
    /// Gain ignores elevation wiggles under `gainHysteresisM` so noise in a
    /// 90 m DEM does not accumulate into hundreds of phantom feet over a long
    /// track. This is the single most important number in the app to get
    /// right, and the hysteresis is why it reads lower (and truer) than naive
    /// summing.
    public static let gainHysteresisM = 3.0

    public static func stats(for coordinates: [Coordinate]) -> RouteStats {
        guard !coordinates.isEmpty else { return .zero }

        // The gain rule itself lives in `gainM(for:)` so a recorded track can
        // apply it per segment without a second copy of it.
        let gainM = gainM(for: coordinates)

        return RouteStats(
            distanceMiles: coordinates.trackLengthM / Units.metersPerMile,
            gainFeet: gainM * Units.feetPerMeter
        )
    }
}

extension Sequence {
    /// Drops nils. Stand-in for the Algorithms package's `compacted()` so the
    /// core stays dependency-free.
    func compacted<Wrapped>() -> [Wrapped] where Element == Wrapped? {
        compactMap { $0 }
    }
}
