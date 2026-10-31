import Foundation

/// The Discover sliders as a value type.
///
/// The ranges, steps and defaults are the web app's, so a search set up the
/// same way returns the same kind of result. Kept out of the view because two
/// of the rules are real logic rather than layout: the high-point handles can
/// cross, and the difficulty slider is a number the user reads as a word.
public struct DiscoverSettings: Sendable, Equatable {
    public var targetMiles: Double = 10
    public var maxEffort: Double = 20
    /// Not a range, because the two handles are independent and either can be
    /// dragged past the other. `highPointRange` sorts them out.
    public var highPointMinFt: Double = 5_000
    public var highPointMaxFt: Double = 14_500
    public var radiusMiles: Double = 20
    /// Drops the current-location anchor and keeps only trailheads above
    /// `DiscoverService.mountainTrailheadFt`.
    public var mountainsOnly: Bool = false

    public init() {}

    // ---------- slider ranges, matching the web app's inputs ----------

    public static let targetRange: ClosedRange<Double> = 2...30
    public static let targetStep = 1.0
    public static let effortRange: ClosedRange<Double> = 5...45
    public static let effortStep = 1.0
    public static let highPointLimits: ClosedRange<Double> = 4_000...14_500
    public static let highPointStep = 500.0
    public static let radiusRange: ClosedRange<Double> = 2...120
    public static let radiusStep = 2.0

    // ---------- derived ----------

    /// The high-point filter, lowest first.
    ///
    /// Dragging the minimum handle past the maximum is easy to do and should
    /// mean what it looks like, not return nothing. The web app swapped the
    /// pair at every read site; doing it once here means a caller cannot
    /// forget.
    public var highPointRange: ClosedRange<Double> {
        min(highPointMinFt, highPointMaxFt)...max(highPointMinFt, highPointMaxFt)
    }

    /// The difficulty cap as the word the slider shows, with the raw score —
    /// "Hard (20)". The number stays visible because the buckets are coarse
    /// and the slider moves within them.
    public var effortLabel: String {
        "\(Effort.bucket(maxEffort).rawValue) (\(Int(maxEffort)))"
    }

    public func options(center: Coordinate) -> DiscoverOptions {
        let highPoint = highPointRange
        return DiscoverOptions(
            center: center,
            targetMiles: targetMiles,
            maxEffort: maxEffort,
            highPointMinFt: highPoint.lowerBound,
            highPointMaxFt: highPoint.upperBound,
            radiusMiles: radiusMiles,
            mountainsOnly: mountainsOnly
        )
    }
}
