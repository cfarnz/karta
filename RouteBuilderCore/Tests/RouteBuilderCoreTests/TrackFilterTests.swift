import Testing
import Foundation
@testable import RouteBuilderCore

// The recorder is new code, not a port, so these expectations come from the
// gates themselves rather than from running JS. Where a distance matters it is
// built with `offset(bearingDegrees:distanceM:)` so the test states metres
// instead of a latitude that happens to be the right number of metres away.

private let trailhead = Coordinate(longitude: -105.2811, latitude: 39.9992)
private let start = Date(timeIntervalSince1970: 1_762_000_000)

private func fix(
    _ coordinate: Coordinate,
    accuracy: Double = 5,
    secondsIn: Double = 0
) -> LocationFix {
    LocationFix(
        coordinate: coordinate,
        horizontalAccuracyM: accuracy,
        timestamp: start.addingTimeInterval(secondsIn)
    )
}

/// Far enough in the future that nothing is stale by wall-clock age.
private let judgedAt = start.addingTimeInterval(1)

@Suite("GPS fixes are filtered before they reach a track")
struct TrackFilterTests {

    // ---------- the problem this exists for ----------

    @Test func `a stationary user with noisy fixes records no distance`() {
        var filter = DistanceAccuracyTrackFilter()
        var total = 0.0

        // 200 readings wandering inside a 6 m circle, the shape of a rest
        // stop. Accepting these is how a recorder reports a hike from a
        // picnic table.
        for i in 0..<200 {
            let bearing = Double(i) * 37  // walks all the way round, repeatedly
            let wobble = trailhead.offset(bearingDegrees: bearing, distanceM: 6)
            let decision = filter.consider(
                fix(wobble, accuracy: 6, secondsIn: Double(i)),
                now: start.addingTimeInterval(Double(i) + 1)
            )
            if case .accepted(let d) = decision { total += d }
        }

        #expect(total == 0)
        // Only the very first reading is on the track.
        #expect(filter.acceptedCount == 1)
        #expect(filter.rejections[.notMovedFarEnough] == 199)
    }

    @Test func `walking in a straight line records every step of it`() {
        var filter = DistanceAccuracyTrackFilter()
        var total = 0.0
        var point = trailhead

        // Standing at the trailhead when recording starts.
        _ = filter.consider(fix(trailhead), now: judgedAt)

        // Then 20 fixes, 30 m apart, one every 30 s — a 1 m/s walk.
        for i in 1...20 {
            point = point.offset(bearingDegrees: 270, distanceM: 30)
            let decision = filter.consider(
                fix(point, secondsIn: Double(i) * 30),
                now: start.addingTimeInterval(Double(i) * 30 + 1)
            )
            if case .accepted(let d) = decision { total += d }
        }

        #expect(filter.acceptedCount == 21)  // the start, plus 20 moves
        #expect(abs(total - 600) < 0.01)
        #expect(filter.rejections.isEmpty)
    }

    // ---------- accuracy gate ----------

    @Test func `a fix wider than the accuracy threshold is dropped`() {
        var filter = DistanceAccuracyTrackFilter()
        let decision = filter.consider(fix(trailhead, accuracy: 25), now: judgedAt)
        #expect(decision == .rejected(.tooInaccurate))
    }

    @Test func `a fix with no accuracy estimate is dropped`() {
        var filter = DistanceAccuracyTrackFilter()
        // CoreLocation signals "unavailable" with a negative number, which
        // would otherwise sail through every comparison as the best reading
        // of the day.
        let decision = filter.consider(fix(trailhead, accuracy: -1), now: judgedAt)
        #expect(decision == .rejected(.noAccuracyEstimate))
    }

    @Test func `a fix exactly at the threshold is kept`() {
        var filter = DistanceAccuracyTrackFilter()
        #expect(filter.consider(fix(trailhead, accuracy: 20), now: judgedAt).isAccepted)
    }

    // ---------- the distance gate scales with accuracy ----------

    @Test func `a sloppy fix must move further than a precise one`() {
        // 18 m of movement: beyond the 15 m floor, inside a 20 m circle.
        let moved = trailhead.offset(bearingDegrees: 90, distanceM: 18)

        var precise = DistanceAccuracyTrackFilter()
        _ = precise.consider(fix(trailhead, accuracy: 5), now: judgedAt)
        #expect(precise.consider(fix(moved, accuracy: 5, secondsIn: 60),
                                 now: start.addingTimeInterval(61)).isAccepted)

        var sloppy = DistanceAccuracyTrackFilter()
        _ = sloppy.consider(fix(trailhead, accuracy: 20), now: judgedAt)
        // Same 18 m, but it cannot be told apart from sitting still inside a
        // 20 m circle. A flat threshold would have banked it.
        #expect(sloppy.consider(fix(moved, accuracy: 20, secondsIn: 60),
                                now: start.addingTimeInterval(61))
                == .rejected(.notMovedFarEnough))
    }

    @Test func `the gate is the floor when the fix is better than the floor`() {
        var filter = DistanceAccuracyTrackFilter()
        _ = filter.consider(fix(trailhead, accuracy: 3), now: judgedAt)
        let short = trailhead.offset(bearingDegrees: 90, distanceM: 14)
        #expect(filter.consider(fix(short, accuracy: 3, secondsIn: 30),
                                now: start.addingTimeInterval(31))
                == .rejected(.notMovedFarEnough))
    }

    // ---------- speed gate ----------

    @Test func `a jump no hiker could make is dropped`() {
        var filter = DistanceAccuracyTrackFilter()
        _ = filter.consider(fix(trailhead), now: judgedAt)
        // 2 km in 10 s. Clean accuracy, plenty far — only the pace gives it
        // away.
        let jump = trailhead.offset(bearingDegrees: 45, distanceM: 2_000)
        #expect(filter.consider(fix(jump, secondsIn: 10),
                                now: start.addingTimeInterval(11))
                == .rejected(.implausibleSpeed))
        // And the track still ends where it was, so the next real fix is
        // measured from the trailhead rather than from the bad point.
        #expect(filter.lastAcceptedFix?.coordinate == trailhead)
    }

    @Test func `a long gap makes a long move plausible again`() {
        var filter = DistanceAccuracyTrackFilter()
        _ = filter.consider(fix(trailhead), now: judgedAt)
        // The same 2 km, after 40 minutes in a dead zone: 0.83 m/s, a walk.
        let later = trailhead.offset(bearingDegrees: 45, distanceM: 2_000)
        #expect(filter.consider(fix(later, secondsIn: 2_400),
                                now: start.addingTimeInterval(2_401)).isAccepted)
    }

    @Test func `a ski descent needs the speed gate raised`() {
        // Documents the tuning rather than asserting a default is right: at
        // the hiking default this is a teleport, and a whole run would vanish.
        let fast = trailhead.offset(bearingDegrees: 180, distanceM: 300)

        var hiking = DistanceAccuracyTrackFilter()
        _ = hiking.consider(fix(trailhead), now: judgedAt)
        #expect(hiking.consider(fix(fast, secondsIn: 10),
                                now: start.addingTimeInterval(11))
                == .rejected(.implausibleSpeed))

        var skiing = DistanceAccuracyTrackFilter(maxSpeedMPS: 35)
        _ = skiing.consider(fix(trailhead), now: judgedAt)
        #expect(skiing.consider(fix(fast, secondsIn: 10),
                                now: start.addingTimeInterval(11)).isAccepted)
    }

    // ---------- time ----------

    @Test func `the cached fix handed over at startup is dropped`() {
        var filter = DistanceAccuracyTrackFilter()
        // CoreLocation delivers its last known position immediately, which
        // can be yesterday's trailhead and would draw a line across the
        // state as the first segment.
        let yesterday = fix(trailhead, secondsIn: -86_400)
        #expect(filter.consider(yesterday, now: judgedAt) == .rejected(.stale))
        #expect(filter.acceptedCount == 0)
    }

    @Test func `a fix older than the one on the track is dropped`() {
        // A generous age gate, so what this test proves is the ordering rule
        // and not the staleness rule standing in front of it.
        var filter = DistanceAccuracyTrackFilter(maxFixAgeS: 600)
        let second = trailhead.offset(bearingDegrees: 90, distanceM: 50)
        _ = filter.consider(fix(trailhead, secondsIn: 0), now: judgedAt)
        _ = filter.consider(fix(second, secondsIn: 60), now: start.addingTimeInterval(61))

        // Arrives after the newer one, which happens when a buffered batch is
        // flushed after a signal gap. Accepting it would walk the track
        // backwards and add the segment twice.
        let late = fix(trailhead, secondsIn: 30)
        #expect(filter.consider(late, now: start.addingTimeInterval(62))
                == .rejected(.outOfOrder))
    }

    // ---------- bookkeeping ----------

    @Test func `reset clears the track and the counters`() {
        var filter = DistanceAccuracyTrackFilter()
        _ = filter.consider(fix(trailhead), now: judgedAt)
        _ = filter.consider(fix(trailhead, secondsIn: 10),
                            now: start.addingTimeInterval(11))
        #expect(filter.acceptedCount == 1)
        #expect(filter.rejections.isEmpty == false)

        filter.reset()
        #expect(filter.acceptedCount == 0)
        #expect(filter.rejections.isEmpty)
        #expect(filter.lastAcceptedFix == nil)
    }

    @Test func `the passthrough filter keeps the raw signal for comparison`() {
        var raw = PassthroughTrackFilter()
        var total = 0.0
        for i in 0..<200 {
            let wobble = trailhead.offset(bearingDegrees: Double(i) * 37, distanceM: 6)
            if case .accepted(let d) = raw.consider(fix(wobble, accuracy: 6, secondsIn: Double(i))) {
                total += d
            }
        }
        // The same stationary 200 readings the filtered test records as zero.
        // Half a kilometre of travel that never happened is what a naive
        // recorder shows; the exact figure is just how far the noise wandered.
        #expect(total > 500)
    }
}
