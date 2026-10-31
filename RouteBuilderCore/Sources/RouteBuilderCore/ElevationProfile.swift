import Foundation

/// One sample along the track, carrying everything the chart and the map
/// cursor both need so the view layer never has to go back to the route.
public struct ProfilePoint: Hashable, Sendable {
    /// Cumulative distance from the start.
    public var distanceMiles: Double
    public var elevationFeet: Double
    /// Where this sample sits on the ground, for the synced map marker.
    public var coordinate: Coordinate

    public init(distanceMiles: Double, elevationFeet: Double, coordinate: Coordinate) {
        self.distanceMiles = distanceMiles
        self.elevationFeet = elevationFeet
        self.coordinate = coordinate
    }
}

/// Distance-versus-elevation along the route, plus the axis ranges to draw it
/// in.
///
/// Separated from the chart on purpose: the accumulation and the domain rules
/// are arithmetic that can be asserted against the web app's numbers, while
/// Swift Charts only ever sees finished points. `profile.js` recomputed all of
/// this inside its render method, which is why none of it was testable there.
public struct ElevationProfile: Sendable, Equatable {
    public var points: [ProfilePoint]
    /// Inclusive x-range in miles. Always starts at zero.
    public var distanceRange: ClosedRange<Double>
    /// Inclusive y-range in feet, after the flat-route floor below.
    public var elevationRange: ClosedRange<Double>

    public static let empty = ElevationProfile(
        points: [], distanceRange: 0...1, elevationRange: 0...100)

    /// A profile needs two points to have any length, so one or none is empty
    /// rather than a degenerate chart.
    public var isEmpty: Bool { points.count < 2 }

    /// The narrowest elevation span the chart will show, in feet.
    ///
    /// Without it, a route along a flat valley floor scales its few feet of
    /// DEM noise to the full height of the plot and reads as a mountain
    /// stage. Matches `profile.js`'s `max(maxE, minE + 100)`.
    public static let minimumElevationSpanFeet = 100.0

    public init(points: [ProfilePoint],
                distanceRange: ClosedRange<Double>,
                elevationRange: ClosedRange<Double>) {
        self.points = points
        self.distanceRange = distanceRange
        self.elevationRange = elevationRange
    }

    /// Builds the profile from a stitched track.
    ///
    /// Unsampled elevations count as zero, as in the web app. That is wrong in
    /// principle and right in practice: elevation arrives for a whole leg at
    /// once, so a nil here means the leg is still in flight and the chart is
    /// about to be rebuilt anyway.
    public init(track: [Coordinate]) {
        guard track.count >= 2 else { self = .empty; return }

        var points: [ProfilePoint] = []
        points.reserveCapacity(track.count)

        var accumulatedM = 0.0
        for (index, coordinate) in track.enumerated() {
            if index > 0 { accumulatedM += track[index - 1].distance(to: coordinate) }
            points.append(ProfilePoint(
                distanceMiles: accumulatedM / Units.metersPerMile,
                elevationFeet: (coordinate.elevation ?? 0) * Units.feetPerMeter,
                coordinate: coordinate
            ))
        }

        // A zero-length track (every point identical) would give an empty
        // x-range, which Swift Charts cannot scale.
        let total = points[points.count - 1].distanceMiles
        let elevations = points.map(\.elevationFeet)
        let lowest = elevations.min() ?? 0
        let highest = max(elevations.max() ?? 0, lowest + Self.minimumElevationSpanFeet)

        self.init(points: points,
                  distanceRange: 0...(total > 0 ? total : 1),
                  elevationRange: lowest...highest)
    }

    // ---------- scrubbing ----------

    /// The sample nearest a distance along the track.
    ///
    /// `profile.js` scanned every point for each mouse move. Distances are
    /// monotonically non-decreasing by construction, so a binary search lands
    /// on the same answer without walking a 2,000-point track on every frame
    /// of a drag.
    public func point(nearestTo distanceMiles: Double) -> ProfilePoint? {
        guard let first = points.first, let last = points.last else { return nil }
        if distanceMiles <= first.distanceMiles { return first }
        if distanceMiles >= last.distanceMiles { return last }

        var low = 0
        var high = points.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if points[mid].distanceMiles <= distanceMiles { low = mid } else { high = mid }
        }

        // Ties go to the earlier point, matching the JS scan's strict `<`.
        let below = points[low]
        let above = points[high]
        return (distanceMiles - below.distanceMiles) <= (above.distanceMiles - distanceMiles)
            ? below : above
    }

    /// The sample nearest a fraction across the plot, which is what a drag
    /// actually produces. Clamped, so a finger dragged past either end sticks
    /// to the first or last point.
    public func point(atFraction fraction: Double) -> ProfilePoint? {
        point(nearestTo: min(1, max(0, fraction)) * distanceRange.upperBound)
    }

    // ---------- readouts ----------

    public var lowestFeet: Double { points.map(\.elevationFeet).min() ?? 0 }
    public var highestFeet: Double { points.map(\.elevationFeet).max() ?? 0 }
}
