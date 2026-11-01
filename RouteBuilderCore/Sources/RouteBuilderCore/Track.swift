import Foundation

// A recorded hike, as distinct from a planned route.
//
// `RouteState` is sparse waypoints plus routed legs, edited freely and
// re-routed on demand. A recording is the opposite: dense, timestamped,
// append-only while it runs and immutable afterwards, because it is evidence
// of where somebody actually was. The two do not share a type, and GPX agrees
// — <trk> for the recorded thing, <rte> for the planned one.
//
// The whole reason this file has as much machinery as it does is gaps. A
// recording stops and starts: the user forgets to unpause and walks 300 yards,
// the signal dies in a drainage, iOS kills the app. Most trackers answer with
// a hole in the line and a distance that is quietly too low — which is exactly
// the number you later use to guess how long the hike takes. So a gap is a
// value here, not an absence, and the two numbers it affects are kept apart:
// what was measured and what was estimated.

public struct TrackPoint: Sendable, Codable, Equatable {
    public var coordinate: Coordinate
    public var timestamp: Date

    public init(coordinate: Coordinate, timestamp: Date) {
        self.coordinate = coordinate
        self.timestamp = timestamp
    }

    /// The fix as recorded, once the filter has accepted it.
    public init(fix: LocationFix) {
        self.coordinate = fix.coordinate
        self.timestamp = fix.timestamp
    }
}

/// One unbroken run of recording. Everything inside it was measured.
public struct TrackSegment: Sendable, Codable, Equatable {
    public var points: [TrackPoint]

    public init(points: [TrackPoint]) {
        self.points = points
    }

    public var coordinates: [Coordinate] { points.map(\.coordinate) }
    public var distanceM: Double { coordinates.trackLengthM }

    /// Wall-clock time spent inside this segment. Zero for a single point.
    public var durationS: Double {
        guard let first = points.first, let last = points.last else { return 0 }
        return last.timestamp.timeIntervalSince(first.timestamp)
    }
}

/// Why the recording stopped.
///
/// Worth keeping even though none of the arithmetic branches on it: a gap the
/// user caused by pressing pause and a gap the sky caused are the same hole in
/// the data and completely different conversations to have with the person who
/// recorded it.
public enum GapCause: String, Sendable, Codable, CaseIterable {
    /// The user pressed pause. If they also moved, they forgot to unpause.
    case userPause
    /// Fixes stopped arriving with the recorder still running.
    case signalLoss
    /// The app was killed or the device died mid-recording.
    case terminated
    case unknown
}

/// What, if anything, stands in for the missing stretch.
public enum GapBridge: Sendable, Codable, Equatable {
    /// Left as a gap. The honest default, and the only one that adds no
    /// distance the device never saw.
    case none
    /// Straight line between the ends. A lower bound: nobody walks the
    /// chord, so the real distance is this or more.
    case straight
    /// A path routed between the ends, which is the best available guess when
    /// both ends sit on trail. The coordinates are kept so the estimate can
    /// be drawn and audited rather than appearing as a number with no shape.
    case routed(coordinates: [Coordinate])

    public var isEstimate: Bool {
        if case .none = self { return false }
        return true
    }
}

/// The hole between two segments.
///
/// Note the asymmetry between the two quantities, because it drives the whole
/// design: **duration is known exactly** — the timestamps either side are
/// real, whether or not anyone knows the path — while **distance can only be
/// estimated**. So elapsed time is always reportable and always honest, and it
/// is the number most trackers throw away.
public struct TrackGap: Sendable, Codable, Equatable {
    /// Last point before the gap.
    public var from: TrackPoint
    /// First point after it.
    public var to: TrackPoint
    public var cause: GapCause
    public var bridge: GapBridge

    public init(from: TrackPoint, to: TrackPoint, cause: GapCause = .unknown, bridge: GapBridge = .none) {
        self.from = from
        self.to = to
        self.cause = cause
        self.bridge = bridge
    }

    /// Exact, from the timestamps.
    public var durationS: Double {
        to.timestamp.timeIntervalSince(from.timestamp)
    }

    /// Straight-line distance between the ends.
    public var straightLineM: Double {
        from.coordinate.distance(to: to.coordinate)
    }

    /// The bridge as a path, or nil when the gap is left alone.
    ///
    /// One definition feeding both the stats and the drawing, so the dashed
    /// line on screen is always exactly the distance the total claims for it.
    /// A routed path is accepted either way round — BRouter returns a full
    /// leg including both ends, but a caller passing only the intermediate
    /// points gets the same answer.
    public var bridgeCoordinates: [Coordinate]? {
        switch bridge {
        case .none:
            return nil
        case .straight:
            return [from.coordinate, to.coordinate]
        case .routed(let coordinates):
            var path = coordinates
            if path.first?.flat != from.coordinate.flat { path.insert(from.coordinate, at: 0) }
            if path.last?.flat != to.coordinate.flat { path.append(to.coordinate) }
            return path
        }
    }

    /// What this gap contributes to the total, given its bridge.
    public var estimatedDistanceM: Double {
        bridgeCoordinates?.trackLengthM ?? 0
    }

    /// Estimated climb across the gap.
    ///
    /// A routed bridge carries sampled elevations, so it gets the same
    /// hysteresis treatment as any other stretch. A straight bridge only
    /// knows its endpoints, so the net rise is the best it can say — and that
    /// is a floor, since an out-and-back over a saddle nets zero.
    public var estimatedGainM: Double {
        switch bridge {
        case .none:
            return 0
        case .straight:
            guard let start = from.coordinate.elevation, let end = to.coordinate.elevation else { return 0 }
            return max(0, end - start)
        case .routed:
            return RouteState.gainM(for: bridgeCoordinates ?? [])
        }
    }

    /// Far enough apart that the two ends are not the same place.
    ///
    /// Sized off the track filter's own movement floor rather than a fresh
    /// constant: below that, the recorder could not have told motion from
    /// noise anyway, so bridging it would add distance that was never walked.
    public static let meaningfulM = 15.0

    /// They pressed pause, walked, and came back to a recording that was
    /// still paused. The case worth asking about by name, because the user
    /// knows exactly what happened and the app can only infer it.
    public var looksLikeForgottenPause: Bool {
        cause == .userPause && straightLineM >= Self.meaningfulM
    }

    /// Unbridged and big enough to matter, so the total is knowably low and
    /// the user is the only one who can say what belongs there.
    public var needsDecision: Bool {
        bridge == .none && straightLineM >= Self.meaningfulM
    }
}

public struct TrackStats: Sendable, Equatable {
    /// Distance the device actually observed.
    public var measuredMiles: Double
    /// Distance attributed to bridged gaps. Kept separate rather than folded
    /// in, so a total can be shown without the estimate being mistaken for a
    /// measurement.
    public var estimatedMiles: Double
    public var measuredGainFeet: Double
    public var estimatedGainFeet: Double
    /// Summed segment durations: time with the recorder running.
    public var movingSeconds: Double
    /// First point to last, gaps included. The number that answers "how long
    /// does this hike take".
    public var elapsedSeconds: Double
    /// Gaps left unbridged and larger than noise — the reason to distrust the
    /// total downward.
    public var unresolvedGapCount: Int

    public var totalMiles: Double { measuredMiles + estimatedMiles }
    public var totalGainFeet: Double { measuredGainFeet + estimatedGainFeet }
    public var gapSeconds: Double { max(0, elapsedSeconds - movingSeconds) }
    public var hasEstimate: Bool { estimatedMiles > 0 || estimatedGainFeet > 0 }

    public static let zero = TrackStats(
        measuredMiles: 0, estimatedMiles: 0,
        measuredGainFeet: 0, estimatedGainFeet: 0,
        movingSeconds: 0, elapsedSeconds: 0,
        unresolvedGapCount: 0
    )
}

/// A span to draw: either recorded line or estimated line, never both.
public struct TrackSpan: Sendable, Equatable {
    public var coordinates: [Coordinate]
    /// Draw dashed. The app already uses dashed for a leg the router could
    /// not find a trail for, and it means the same thing here — this line is
    /// our guess, not the ground.
    public var isEstimated: Bool
}

public struct Track: Sendable, Codable, Equatable {
    public var name: String
    /// One per unbroken run of recording. Never empty for a track that has
    /// recorded anything.
    public var segments: [TrackSegment]
    /// Parallel to the joins between segments, so `gaps.count` is always
    /// `segments.count - 1`. Same parallel-array shape as `RouteState.legs`,
    /// for the same reason: the relationship is positional and a dictionary
    /// would let it drift.
    public var gaps: [TrackGap]

    /// How many points came from a stretch recovered out of a pause.
    ///
    /// Provenance rather than arithmetic: those points are measured, so they
    /// count like any others, but they were sampled coarsely and the sources
    /// panel should be able to say so.
    public var recoveredPointCount: Int = 0

    public init(name: String = "Recording", segments: [TrackSegment] = [], gaps: [TrackGap] = []) {
        self.name = name
        self.segments = segments
        self.gaps = gaps
    }

    public var isEmpty: Bool { segments.allSatisfy(\.points.isEmpty) }

    public var firstPoint: TrackPoint? { segments.first(where: { !$0.points.isEmpty })?.points.first }
    public var lastPoint: TrackPoint? { segments.last(where: { !$0.points.isEmpty })?.points.last }

    /// Gaps the user should be asked about when they stop recording. Asking
    /// mid-hike would interrupt the thing being recorded; asking at save time
    /// is the one moment they still remember what happened.
    public var gapsNeedingDecision: [TrackGap] { gaps.filter(\.needsDecision) }

    public var stats: TrackStats {
        guard let first = firstPoint, let last = lastPoint else { return .zero }

        let measuredM = segments.reduce(0) { $0 + $1.distanceM }
        let estimatedM = gaps.reduce(0) { $0 + $1.estimatedDistanceM }
        // Gain is summed per segment rather than over one stitched list, so
        // the elevation step across a gap is never banked as climb. Whatever
        // happened in there belongs to the gap's own estimate.
        let measuredGainM = segments.reduce(0) { $0 + RouteState.gainM(for: $1.coordinates) }
        let estimatedGainM = gaps.reduce(0) { $0 + $1.estimatedGainM }

        return TrackStats(
            measuredMiles: measuredM / Units.metersPerMile,
            estimatedMiles: estimatedM / Units.metersPerMile,
            measuredGainFeet: measuredGainM * Units.feetPerMeter,
            estimatedGainFeet: estimatedGainM * Units.feetPerMeter,
            movingSeconds: segments.reduce(0) { $0 + $1.durationS },
            elapsedSeconds: last.timestamp.timeIntervalSince(first.timestamp),
            unresolvedGapCount: gapsNeedingDecision.count
        )
    }

    /// Recorded and estimated spans in order, ready to draw.
    ///
    /// A bridge span carries the endpoints either side, so the dashed line
    /// meets the solid ones instead of floating with a gap at each end.
    public var spans: [TrackSpan] {
        var out: [TrackSpan] = []
        for (index, segment) in segments.enumerated() where !segment.points.isEmpty {
            out.append(TrackSpan(coordinates: segment.coordinates, isEstimated: false))
            guard index < gaps.count else { continue }
            guard let bridge = gaps[index].bridgeCoordinates else { continue }
            out.append(TrackSpan(coordinates: bridge, isEstimated: true))
        }
        return out
    }

    // ---------- building ----------

    /// Appends an accepted fix to the open segment, starting one if needed.
    public mutating func append(_ point: TrackPoint) {
        if segments.isEmpty { segments.append(TrackSegment(points: [])) }
        segments[segments.count - 1].points.append(point)
    }

    /// Closes the current segment and records why.
    ///
    /// A break with nothing recorded yet, or two breaks in a row, would leave
    /// an empty segment and a gap with no ends, so both are ignored. The
    /// gap's ends are filled in by `resume`, which is the first moment the far
    /// end exists.
    public mutating func markBreak(cause: GapCause) {
        guard let last = lastPoint, segments.last?.points.isEmpty == false else { return }
        pendingBreak = PendingBreak(from: last, cause: cause)
    }

    /// Reopens recording. If a break is outstanding this is where the gap gets
    /// made, now that both of its ends are known.
    public mutating func resume(at point: TrackPoint) {
        if let pending = pendingBreak {
            gaps.append(TrackGap(from: pending.from, to: point, cause: pending.cause))
            segments.append(TrackSegment(points: [point]))
            pendingBreak = nil
            return
        }
        append(point)
    }

    public mutating func applyBridge(_ bridge: GapBridge, toGapAt index: Int) {
        guard gaps.indices.contains(index) else { return }
        gaps[index].bridge = bridge
    }

    /// Held between `markBreak` and `resume` because a gap cannot be built
    /// until its far end arrives — and the recording may well end instead, in
    /// which case there is no gap, just a finished track.
    private struct PendingBreak: Sendable, Codable, Equatable {
        var from: TrackPoint
        var cause: GapCause
    }

    private var pendingBreak: PendingBreak?
}

extension RouteState {
    /// Cumulative gain in metres, hysteresis and all.
    ///
    /// Pulled out of `stats(for:)` so a track can reuse the identical
    /// treatment per segment. Two copies of the gain rule would eventually
    /// disagree, and gain is the number in this app least able to afford that.
    public static func gainM(for coordinates: [Coordinate]) -> Double {
        guard let first = coordinates.first else { return 0 }

        var gainM = 0.0
        var reference = first.elevation ?? 0

        for coordinate in coordinates {
            let elevation = coordinate.elevation ?? reference
            if elevation > reference + gainHysteresisM {
                gainM += elevation - reference
                reference = elevation
            } else if elevation < reference - gainHysteresisM {
                reference = elevation
            }
        }
        return gainM
    }
}
