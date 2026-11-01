import Testing
import Foundation
@testable import RouteBuilderCore

// The recorder has no counterpart in the web app, so these expectations come
// from the gap rules rather than from running JS. Distances are built with
// `offset(bearingDegrees:distanceM:)` so a test states metres rather than a
// latitude that happens to be the right number of metres away.

private let trailhead = Coordinate(longitude: -105.2811, latitude: 39.9992, elevation: 1_760)
private let start = Date(timeIntervalSince1970: 1_762_000_000)

private func point(_ coordinate: Coordinate, secondsIn: Double) -> TrackPoint {
    TrackPoint(coordinate: coordinate, timestamp: start.addingTimeInterval(secondsIn))
}

/// A straight walk west: `count` points `spacingM` apart, one per `everyS`,
/// climbing `climbM` per point.
private func walk(
    from origin: Coordinate,
    count: Int,
    spacingM: Double = 50,
    everyS: Double = 60,
    climbM: Double = 0,
    startingAt secondsIn: Double = 0
) -> [TrackPoint] {
    var out: [TrackPoint] = []
    var coordinate = origin
    // Carried along explicitly because `offset` returns a coordinate with no
    // elevation — reading it back off the new point climbs from sea level.
    var elevation = origin.elevation ?? 0
    for i in 0..<count {
        if i > 0 {
            coordinate = coordinate.offset(bearingDegrees: 270, distanceM: spacingM)
            elevation += climbM
            coordinate.elevation = elevation
        }
        out.append(point(coordinate, secondsIn: secondsIn + Double(i) * everyS))
    }
    return out
}

@Suite("A recorded track keeps its gaps")
struct TrackTests {

    // ---------- the case this exists for ----------

    /// Paused at a creek, walked 300 yards, forgot to unpause.
    private func forgottenPause() -> Track {
        var track = Track(name: "Royal Arch")
        for p in walk(from: trailhead, count: 6) { track.append(p) }   // 250 m
        track.markBreak(cause: .userPause)

        // 300 yards on from where the recording stopped, six minutes later.
        let resumeAt = track.lastPoint!.coordinate
            .offset(bearingDegrees: 270, distanceM: 274)
        for (i, p) in walk(from: resumeAt, count: 6, startingAt: 660).enumerated() {
            i == 0 ? track.resume(at: p) : track.append(p)
        }
        return track
    }

    @Test func `a forgotten pause is a gap, not a hole in the numbers`() {
        let track = forgottenPause()

        #expect(track.segments.count == 2)
        #expect(track.gaps.count == 1)

        let gap = track.gaps[0]
        // The user knows what happened here and the app can only infer it, so
        // this is the one worth naming.
        #expect(gap.looksLikeForgottenPause)
        #expect(gap.needsDecision)
        #expect(abs(gap.straightLineM - 274) < 0.5)

        let stats = track.stats
        #expect(abs(stats.measuredMiles - 500 / Units.metersPerMile) < 1e-6)
        // Nothing invented until somebody asks for it.
        #expect(stats.estimatedMiles == 0)
        #expect(stats.unresolvedGapCount == 1)
    }

    @Test func `the gap's duration is exact even though its distance is not`() {
        let gap = forgottenPause().gaps[0]
        // Six minutes of wall clock between the timestamps either side. This
        // is knowable; the path across it never will be.
        #expect(gap.durationS == 360)
    }

    @Test func `elapsed time counts the gap and moving time does not`() {
        let stats = forgottenPause().stats
        #expect(stats.movingSeconds == 600)    // two five-minute segments
        #expect(stats.elapsedSeconds == 960)   // plus the six-minute gap
        #expect(stats.gapSeconds == 360)
        // The number you actually want when guessing how long this hike takes
        // is the elapsed one, and it survives the pause intact.
    }

    // ---------- bridging ----------

    @Test func `a straight bridge is a floor on the missing distance`() {
        var track = forgottenPause()
        track.applyBridge(.straight, toGapAt: 0)

        let stats = track.stats
        #expect(abs(stats.estimatedMiles - 274 / Units.metersPerMile) < 1e-6)
        // Measured is untouched by the bridge. That separation is the point:
        // a total can be shown without the estimate passing as a measurement.
        #expect(abs(stats.measuredMiles - 500 / Units.metersPerMile) < 1e-6)
        #expect(abs(stats.totalMiles - 774 / Units.metersPerMile) < 1e-6)
        #expect(stats.hasEstimate)
        #expect(stats.unresolvedGapCount == 0)
    }

    @Test func `a routed bridge measures the trail it was given`() {
        var track = forgottenPause()
        let gap = track.gaps[0]
        // A path that wanders rather than cutting the chord, which is what a
        // trail does and why a routed bridge beats a straight one.
        let detour = gap.from.coordinate.offset(bearingDegrees: 315, distanceM: 150)
        track.applyBridge(.routed(coordinates: [detour]), toGapAt: 0)

        let bridged = [gap.from.coordinate, detour, gap.to.coordinate].trackLengthM
        #expect(bridged > gap.straightLineM)  // no route is shorter than the chord
        #expect(abs(track.stats.estimatedMiles - bridged / Units.metersPerMile) < 1e-6)
    }

    @Test func `a routed path that already names its ends is not doubled`() {
        var track = forgottenPause()
        let gap = track.gaps[0]
        let detour = gap.from.coordinate.offset(bearingDegrees: 315, distanceM: 150)

        // BRouter returns a full leg, ends included. Passing only the middle
        // has to give the same answer, or the number depends on who built the
        // array.
        var full = track
        full.applyBridge(.routed(coordinates: [gap.from.coordinate, detour, gap.to.coordinate]),
                         toGapAt: 0)
        track.applyBridge(.routed(coordinates: [detour]), toGapAt: 0)

        #expect(full.stats.estimatedMiles == track.stats.estimatedMiles)
        #expect(full.spans[1].coordinates.count == 3)
    }

    @Test func `an unbridged gap adds nothing anywhere`() {
        let track = forgottenPause()
        #expect(track.gaps[0].estimatedDistanceM == 0)
        #expect(track.gaps[0].estimatedGainM == 0)
        #expect(track.stats.hasEstimate == false)
    }

    @Test func `stepping off at the same spot is not worth asking about`() {
        var track = Track()
        for p in walk(from: trailhead, count: 4) { track.append(p) }
        track.markBreak(cause: .userPause)
        // Resumed 5 m away after a genuine rest: inside the distance the
        // filter could not tell from noise in the first place.
        let nearby = track.lastPoint!.coordinate.offset(bearingDegrees: 90, distanceM: 5)
        track.resume(at: point(nearby, secondsIn: 900))

        #expect(track.gaps[0].needsDecision == false)
        #expect(track.gaps[0].looksLikeForgottenPause == false)
        #expect(track.gapsNeedingDecision.isEmpty)
        // The rest still shows up as time, which is the honest record of it.
        #expect(track.stats.gapSeconds > 0)
    }

    // ---------- gain ----------

    @Test func `gain is summed per segment so a gap is never banked as climb`() {
        var track = Track()
        for p in walk(from: trailhead, count: 6, climbM: 20) { track.append(p) }  // +100 m
        track.markBreak(cause: .signalLoss)

        // Reappears 300 m higher, which is what a drainage with no sky looks
        // like. Stitching the two segments into one list would hand that
        // whole 300 m step to the gain total as though it had been measured.
        var higher = track.lastPoint!.coordinate.offset(bearingDegrees: 270, distanceM: 274)
        higher.elevation = (track.lastPoint!.coordinate.elevation ?? 0) + 300
        for (i, p) in walk(from: higher, count: 6, climbM: 20, startingAt: 660).enumerated() {
            i == 0 ? track.resume(at: p) : track.append(p)
        }

        let stats = track.stats
        #expect(abs(stats.measuredGainFeet - 200 * Units.feetPerMeter) < 0.01)
        #expect(stats.estimatedGainFeet == 0)
    }

    @Test func `a straight bridge's gain is the net rise between its ends`() {
        var track = Track()
        for p in walk(from: trailhead, count: 3) { track.append(p) }
        track.markBreak(cause: .userPause)
        var higher = track.lastPoint!.coordinate.offset(bearingDegrees: 270, distanceM: 274)
        higher.elevation = (track.lastPoint!.coordinate.elevation ?? 0) + 60
        track.resume(at: point(higher, secondsIn: 600))
        track.applyBridge(.straight, toGapAt: 0)

        // A floor, not a measurement: an out-and-back over a saddle in there
        // would net the same 60 m having climbed far more.
        #expect(abs(track.stats.estimatedGainFeet - 60 * Units.feetPerMeter) < 0.01)
    }

    @Test func `a descent across a bridge contributes no gain`() {
        var track = Track()
        for p in walk(from: trailhead, count: 3) { track.append(p) }
        track.markBreak(cause: .signalLoss)
        var lower = track.lastPoint!.coordinate.offset(bearingDegrees: 270, distanceM: 274)
        lower.elevation = (track.lastPoint!.coordinate.elevation ?? 0) - 100
        track.resume(at: point(lower, secondsIn: 600))
        track.applyBridge(.straight, toGapAt: 0)

        #expect(track.stats.estimatedGainFeet == 0)
    }

    @Test func `segment gain uses the same hysteresis as a planned route`() {
        // The oscillating-noise case the web app gets wrong is pinned in
        // RouteTests; this only asserts a track goes through the same rule
        // rather than growing a second copy of it.
        let noisy = (0..<40).map { i -> TrackPoint in
            var c = trailhead.offset(bearingDegrees: 270, distanceM: Double(i) * 50)
            c.elevation = 1_760 + (i.isMultiple(of: 2) ? 0 : 2)
            return point(c, secondsIn: Double(i) * 60)
        }
        var track = Track()
        for p in noisy { track.append(p) }

        let segment = TrackSegment(points: noisy)
        #expect(track.stats.measuredGainFeet
                == RouteState.gainM(for: segment.coordinates) * Units.feetPerMeter)
    }

    // ---------- drawing ----------

    @Test func `spans alternate recorded and estimated for the dashed line`() {
        var track = forgottenPause()

        // Unbridged: two solid runs and nothing between them.
        #expect(track.spans.count == 2)
        #expect(track.spans.allSatisfy { !$0.isEstimated })

        track.applyBridge(.straight, toGapAt: 0)
        let spans = track.spans
        #expect(spans.map(\.isEstimated) == [false, true, false])
        // The dashed span repeats the endpoints either side so it meets the
        // solid lines instead of floating.
        #expect(spans[1].coordinates.first == spans[0].coordinates.last)
        #expect(spans[1].coordinates.last == spans[2].coordinates.first)
    }

    @Test func `a routed bridge draws the path it was given, ends included`() {
        var track = forgottenPause()
        let detour = track.gaps[0].from.coordinate.offset(bearingDegrees: 315, distanceM: 150)
        track.applyBridge(.routed(coordinates: [detour]), toGapAt: 0)

        let bridge = track.spans[1]
        #expect(bridge.isEstimated)
        #expect(bridge.coordinates.count == 3)
        #expect(bridge.coordinates[1] == detour)
    }

    // ---------- building ----------

    @Test func `a break before anything is recorded makes no gap`() {
        var track = Track()
        track.markBreak(cause: .userPause)
        track.resume(at: point(trailhead, secondsIn: 0))
        #expect(track.gaps.isEmpty)
        #expect(track.segments.count == 1)
    }

    @Test func `two breaks in a row make one gap`() {
        var track = Track()
        for p in walk(from: trailhead, count: 3) { track.append(p) }
        track.markBreak(cause: .userPause)
        // The recorder stopping twice without a fix in between — a double tap,
        // or a signal loss straight after a pause.
        track.markBreak(cause: .signalLoss)
        let onwards = track.lastPoint!.coordinate.offset(bearingDegrees: 270, distanceM: 274)
        track.resume(at: point(onwards, secondsIn: 600))

        #expect(track.gaps.count == 1)
        #expect(track.segments.count == 2)
        // The later cause wins, which is the one that actually ended the
        // recording.
        #expect(track.gaps[0].cause == .signalLoss)
    }

    @Test func `a recording that ends on a break has no trailing gap`() {
        var track = Track()
        for p in walk(from: trailhead, count: 3) { track.append(p) }
        track.markBreak(cause: .terminated)
        // Never resumed. A gap needs two ends, and this has one.
        #expect(track.gaps.isEmpty)
        #expect(track.segments.count == 1)
        #expect(track.stats.unresolvedGapCount == 0)
    }

    @Test func `an empty track has zero stats rather than a crash`() {
        #expect(Track().stats == .zero)
        #expect(Track().isEmpty)
        #expect(Track().spans.isEmpty)
    }

    @Test func `a single point has no distance and no duration`() {
        var track = Track()
        track.append(point(trailhead, secondsIn: 0))
        #expect(track.stats.measuredMiles == 0)
        #expect(track.stats.elapsedSeconds == 0)
        #expect(track.stats.movingSeconds == 0)
    }

    @Test func `bridging a gap that does not exist is ignored`() {
        var track = forgottenPause()
        track.applyBridge(.straight, toGapAt: 7)
        #expect(track.stats.estimatedMiles == 0)
    }

    @Test func `accepted fixes become track points`() {
        let fix = LocationFix(
            coordinate: trailhead,
            horizontalAccuracyM: 6,
            timestamp: start
        )
        #expect(TrackPoint(fix: fix) == point(trailhead, secondsIn: 0))
    }

    // ---------- GPX ----------

    @Test func `each segment is written as its own trkseg`() {
        let gpx = GPX.document(for: forgottenPause())

        // Multiple trksegs in one trk is exactly what the spec has them for,
        // and it is how the pause survives into Gaia or COROS instead of
        // being flattened into a line through the gap.
        #expect(gpx.components(separatedBy: "<trkseg>").count - 1 == 2)
        #expect(gpx.components(separatedBy: "<trk>").count - 1 == 1)
        #expect(gpx.contains("<name>Royal Arch</name>"))
    }

    @Test func `a bridged gap is never written as track points`() {
        var track = forgottenPause()
        let before = GPX.document(for: track)
            .components(separatedBy: "<trkpt").count
        track.applyBridge(.straight, toGapAt: 0)
        let after = GPX.document(for: track)
            .components(separatedBy: "<trkpt").count

        // An estimate written as a trkpt is indistinguishable from measured
        // GPS forever after, in this app and every other one.
        #expect(before == after)
        #expect(track.stats.estimatedMiles > 0)  // it is in the stats, just not the file
    }

    @Test func `track points carry a UTC timestamp after the elevation`() {
        let gpx = GPX.document(for: forgottenPause())
        #expect(gpx.contains("<ele>1760.0</ele><time>2025-11-01T"))
        #expect(gpx.contains("Z</time>"))
    }

    @Test func `an empty recording still writes a valid document`() {
        let gpx = GPX.document(for: Track(name: "Nothing"))
        #expect(gpx.contains("<trk>"))
        #expect(gpx.contains("<trkseg>") == false)
    }

    @Test func `exporting a planned route is unchanged`() {
        // The route export is the shipping path and the track writer must not
        // have moved it.
        let gpx = GPX.document(for: [trailhead], name: "Route")
        #expect(gpx.contains(#"<trkpt lat="39.999200" lon="-105.281100"><ele>1760.0</ele></trkpt>"#))
        #expect(gpx.contains("<time>") == false)
    }
}
