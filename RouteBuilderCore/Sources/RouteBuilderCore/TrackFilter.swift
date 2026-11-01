import Foundation

// Deciding which GPS fixes belong in a recorded track.
//
// A raw CoreLocation stream is not a track. Standing still, the estimate
// wanders inside its own accuracy circle, and a recorder that accepts every
// fix accumulates miles from a picnic. Under canopy or in a canyon the
// wandering gets worse, and the occasional fix lands hundreds of metres away
// outright.
//
// Unlike the rest of this package, these numbers are not ported from the web
// app — it has no recorder — so the tests assert the behaviour of the gates
// rather than agreement with a JS reference.
//
// The shape of the solution is the one HERE's hiking sample uses (accuracy
// gate + distance gate behind a strategy protocol), with four changes that
// matter in the field: the distance gate scales with the accuracy of the fix
// being judged, a speed gate rejects teleports, stale fixes are dropped, and
// every rejection carries a reason so the sources panel can say why a track
// stopped growing.

/// One reading from the device, in the terms the filter judges.
///
/// Built from `CLLocation` at the app layer: `coordinate`, `timestamp`,
/// `horizontalAccuracy` and `speed` map across directly. CoreLocation reports
/// an unavailable accuracy or speed as a *negative* number rather than nil,
/// and that sentinel is preserved here on purpose — the filter is the one
/// place that should know about it.
public struct LocationFix: Sendable, Equatable {
    public var coordinate: Coordinate
    /// Radius in metres containing the true position with ~68% probability.
    /// Negative means the device could not estimate it.
    public var horizontalAccuracyM: Double
    public var timestamp: Date
    /// Instantaneous speed in metres per second, or negative when unknown.
    /// Only used as a cross-check; the filter's own speed test works off
    /// consecutive positions, which is the number that actually bounds the
    /// track.
    public var speedMPS: Double

    public init(
        coordinate: Coordinate,
        horizontalAccuracyM: Double,
        timestamp: Date,
        speedMPS: Double = -1
    ) {
        self.coordinate = coordinate
        self.horizontalAccuracyM = horizontalAccuracyM
        self.timestamp = timestamp
        self.speedMPS = speedMPS
    }
}

/// Why a fix was not recorded.
///
/// Worth an enum rather than a bare `false`: "the GPS is bad" and "you have
/// not moved" look identical on a frozen track and call for opposite
/// responses from the person holding the phone.
public enum FixRejection: String, Sendable, Equatable, CaseIterable {
    /// The device reported no usable accuracy estimate at all.
    case noAccuracyEstimate
    /// The accuracy circle is wider than the threshold.
    case tooInaccurate
    /// Older than `maxFixAgeS` — typically the cached fix CoreLocation hands
    /// over immediately on start, which can be yesterday's parking lot.
    case stale
    /// Timestamped at or before the last accepted fix. Out-of-order
    /// deliveries happen after a signal gap.
    case outOfOrder
    /// Inside the noise: not far enough from the last accepted fix to be
    /// distinguishable from standing still.
    case notMovedFarEnough
    /// Far enough, but not reachable in the elapsed time at a human pace.
    case implausibleSpeed
}

public enum FixDecision: Sendable, Equatable {
    /// Recorded. Carries the distance from the previously accepted fix, which
    /// is the segment the caller should add to its running total — recomputing
    /// it at the call site would be a second source of truth for mileage.
    case accepted(distanceFromLastM: Double)
    case rejected(FixRejection)

    public var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }
}

/// Swappable so a debug build can record raw fixes for comparison, and so the
/// gates can be tuned per activity without the recorder knowing.
public protocol TrackFilterStrategy: Sendable {
    mutating func consider(_ fix: LocationFix) -> FixDecision
    mutating func reset()
}

/// Accepts a fix when the reading is trustworthy *and* describes real motion.
public struct DistanceAccuracyTrackFilter: TrackFilterStrategy, Sendable {

    /// Widest accuracy circle still worth recording.
    ///
    /// HERE's sample uses 10 m, which is clean open-sky GPS. On a trail under
    /// canopy, in a drainage, or anywhere with half the sky behind rock, 10 m
    /// discards nearly everything and the track simply stops — the failure
    /// looks like a bug rather than a filter. 20 m keeps recording where
    /// people actually hike, and the distance gate below absorbs the extra
    /// slop by scaling with it.
    public var maxAccuracyM: Double
    /// Floor for the movement gate, used when the fix is better than this.
    public var minDistanceM: Double
    /// Metres per second. 10 m/s is 22 mph — above any hiker or trail runner,
    /// below a car. Raise it for lift-served skiing or anything with a motor,
    /// or a descent will read as a teleport and the whole run will be
    /// dropped.
    public var maxSpeedMPS: Double
    /// How old a fix may be when it arrives.
    public var maxFixAgeS: Double

    private var lastAccepted: LocationFix?

    /// Counts by reason, for the sources panel and for answering "why is my
    /// distance not moving" without a debugger.
    public private(set) var acceptedCount = 0
    public private(set) var rejections: [FixRejection: Int] = [:]

    public init(
        maxAccuracyM: Double = 20,
        minDistanceM: Double = 15,
        maxSpeedMPS: Double = 10,
        maxFixAgeS: Double = 10
    ) {
        self.maxAccuracyM = maxAccuracyM
        self.minDistanceM = minDistanceM
        self.maxSpeedMPS = maxSpeedMPS
        self.maxFixAgeS = maxFixAgeS
    }

    /// `now` is injected so the age test is testable; the recorder passes
    /// nothing and gets the wall clock.
    public mutating func consider(_ fix: LocationFix, now: Date = Date()) -> FixDecision {
        if fix.horizontalAccuracyM < 0 { return reject(.noAccuracyEstimate) }
        if fix.horizontalAccuracyM > maxAccuracyM { return reject(.tooInaccurate) }
        // A fix from the future is a clock adjustment mid-hike, not an error
        // worth dropping, so only the past is checked.
        if now.timeIntervalSince(fix.timestamp) > maxFixAgeS { return reject(.stale) }

        guard let last = lastAccepted else {
            // The first fix has nothing to be far from. It still had to pass
            // the accuracy and age gates, so the track starts somewhere real.
            return accept(fix, distance: 0)
        }

        let elapsed = fix.timestamp.timeIntervalSince(last.timestamp)
        if elapsed <= 0 { return reject(.outOfOrder) }

        let distance = fix.coordinate.distance(to: last.coordinate)

        // The gate is the larger of the floor and this fix's own accuracy
        // radius. A 5 m fix only has to clear 15 m, but a 20 m fix has to
        // clear 20 m, because anything less is inside the circle it could
        // have been sitting in all along. This is the one change from HERE's
        // flat threshold that does real work: with a flat 15 m, a stretch of
        // 18 m readings drifts the track forward while the user eats lunch.
        let gate = max(minDistanceM, fix.horizontalAccuracyM)
        if distance < gate { return reject(.notMovedFarEnough) }

        if distance / elapsed > maxSpeedMPS { return reject(.implausibleSpeed) }

        return accept(fix, distance: distance)
    }

    public mutating func consider(_ fix: LocationFix) -> FixDecision {
        consider(fix, now: Date())
    }

    public mutating func reset() {
        lastAccepted = nil
        acceptedCount = 0
        rejections = [:]
    }

    /// The fix the track currently ends at, or nil before the first accept.
    public var lastAcceptedFix: LocationFix? { lastAccepted }

    private mutating func accept(_ fix: LocationFix, distance: Double) -> FixDecision {
        lastAccepted = fix
        acceptedCount += 1
        return .accepted(distanceFromLastM: distance)
    }

    private mutating func reject(_ reason: FixRejection) -> FixDecision {
        rejections[reason, default: 0] += 1
        return .rejected(reason)
    }
}

/// Accepts everything. For a debug overlay that draws the raw signal next to
/// the filtered one — seeing the two together is how you tell a filter that
/// is too strict from a GPS that is having a bad day.
public struct PassthroughTrackFilter: TrackFilterStrategy, Sendable {
    private var lastAccepted: LocationFix?

    public init() {}

    public mutating func consider(_ fix: LocationFix) -> FixDecision {
        let distance = lastAccepted.map { fix.coordinate.distance(to: $0.coordinate) } ?? 0
        lastAccepted = fix
        return .accepted(distanceFromLastM: distance)
    }

    public mutating func reset() { lastAccepted = nil }
}
