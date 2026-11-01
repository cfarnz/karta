import Testing
import Foundation
@testable import RouteBuilderCore

// The session has no counterpart in the web app either, so these assert the
// state machine's rules. Fixes are built at real metre spacings with
// `offset(bearingDegrees:distanceM:)`.

private let trailhead = Coordinate(longitude: -106.4752, latitude: 39.1875)  // Mt Massive
private let start = Date(timeIntervalSince1970: 1_762_000_000)

private func fix(_ coordinate: Coordinate, accuracy: Double = 6, secondsIn: Double) -> LocationFix {
    LocationFix(coordinate: coordinate, horizontalAccuracyM: accuracy,
                timestamp: start.addingTimeInterval(secondsIn))
}

/// Feeds a straight walk into the recorder and returns the events, so a test
/// can assert on what the session did rather than reconstructing it.
@discardableResult
private func walk(
    _ recorder: inout TrackRecorder,
    from origin: Coordinate,
    count: Int,
    spacingM: Double = 40,
    everyS: Double = 30,
    startingAt secondsIn: Double
) -> (last: Coordinate, lastTime: Double, events: [RecorderEvent]) {
    var coordinate = origin
    var time = secondsIn
    var events: [RecorderEvent] = []
    for i in 0..<count {
        if i > 0 {
            coordinate = coordinate.offset(bearingDegrees: 270, distanceM: spacingM)
            time += everyS
        }
        events.append(recorder.consider(fix(coordinate, secondsIn: time),
                                        now: start.addingTimeInterval(time + 1)))
    }
    return (coordinate, time, events)
}

@Suite("The recording session")
struct TrackRecorderTests {

    @Test func `a plain walk records every fix and opens no gaps`() {
        var recorder = TrackRecorder()
        recorder.start()
        let walked = walk(&recorder, from: trailhead, count: 10, startingAt: 0)

        #expect(walked.events.allSatisfy { if case .recorded = $0 { return true } else { return false } })
        #expect(recorder.track.segments.count == 1)
        #expect(recorder.track.gaps.isEmpty)
        #expect(abs(recorder.track.stats.measuredMiles - 360 / Units.metersPerMile) < 1e-6)
        #expect(recorder.state == .recording)
    }

    @Test func `a fix before starting is not recorded`() {
        var recorder = TrackRecorder()
        #expect(recorder.consider(fix(trailhead, secondsIn: 0),
                                  now: start.addingTimeInterval(1)) == .notRecording)
        #expect(recorder.track.isEmpty)
    }

    // ---------- layer one: the pause keeps listening ----------

    @Test func `walking through a manual pause is recovered, not estimated`() {
        var recorder = TrackRecorder()
        recorder.start()
        let walked = walk(&recorder, from: trailhead, count: 6, startingAt: 0)

        recorder.pause()
        #expect(recorder.state == .paused(.manual))

        // 300 yards on, over six minutes, with the recording still paused —
        // the exact case that leaves a hole in most trackers.
        var coordinate = walked.last
        var time = walked.lastTime
        for _ in 0..<6 {
            coordinate = coordinate.offset(bearingDegrees: 270, distanceM: 46)
            time += 60
            #expect(recorder.consider(fix(coordinate, secondsIn: time),
                                      now: start.addingTimeInterval(time + 1)) == .buffered)
        }
        // Buffered means not on the track and not lost.
        #expect(abs(recorder.track.stats.measuredMiles - 200 / Units.metersPerMile) < 1e-6)

        guard case .recoveryAvailable(let stretch) = recorder.resume() else {
            Issue.record("expected a recovery to be offered")
            return
        }
        #expect(abs(stretch.distanceM - 276) < 1)
        #expect(stretch.durationS == 360)

        recorder.acceptRecovery()

        // Still one segment and still no gap: nothing was ever missing, it was
        // only set aside. This is the whole difference from bridging.
        #expect(recorder.track.segments.count == 1)
        #expect(recorder.track.gaps.isEmpty)
        #expect(recorder.track.stats.hasEstimate == false)
        #expect(abs(recorder.track.stats.measuredMiles - 476 / Units.metersPerMile) < 1e-5)
        #expect(recorder.track.recoveredPointCount == 6)
    }

    @Test func `rejecting a recovered stretch leaves a gap instead`() {
        var recorder = TrackRecorder()
        recorder.start()
        let walked = walk(&recorder, from: trailhead, count: 6, startingAt: 0)

        recorder.pause()
        var coordinate = walked.last
        var time = walked.lastTime
        for _ in 0..<6 {
            coordinate = coordinate.offset(bearingDegrees: 270, distanceM: 46)
            time += 60
            _ = recorder.consider(fix(coordinate, secondsIn: time),
                                  now: start.addingTimeInterval(time + 1))
        }
        _ = recorder.resume()
        // "That is not where I went." The stretch becomes unknown rather than
        // wrong, which is what a gap is for.
        recorder.discardRecovery()

        // The gap's far end does not exist until the next real fix.
        #expect(recorder.track.gaps.isEmpty)
        let onwards = walk(&recorder, from: coordinate, count: 3, startingAt: time + 60)

        #expect(recorder.track.segments.count == 2)
        #expect(recorder.track.gaps.count == 1)
        #expect(recorder.track.gaps[0].cause == .userPause)
        #expect(recorder.track.gaps[0].looksLikeForgottenPause)
        #expect(recorder.track.gapsNeedingDecision.count == 1)
        _ = onwards
    }

    @Test func `pausing and resuming in one place adds no gap and no distance`() {
        var recorder = TrackRecorder()
        recorder.start()
        let walked = walk(&recorder, from: recorder.track.lastPoint?.coordinate ?? trailhead,
                          count: 5, startingAt: 0)

        recorder.pause()
        // A twenty-minute lunch. Fixes keep arriving and the coarse filter
        // discards them all, because nobody moved.
        var time = walked.lastTime
        for _ in 0..<20 {
            time += 60
            _ = recorder.consider(fix(walked.last, secondsIn: time),
                                  now: start.addingTimeInterval(time + 1))
        }
        #expect(recorder.resume() == .recorded(distanceM: 0))

        #expect(recorder.track.gaps.isEmpty)
        #expect(recorder.track.segments.count == 1)
        #expect(recorder.pendingRecovery == nil)
        // The rest is still in the record, as time.
        #expect(recorder.track.stats.gapSeconds == 0)
    }

    @Test func `a manual pause never ends itself however far they walk`() {
        var recorder = TrackRecorder()
        recorder.start()
        let walked = walk(&recorder, from: trailhead, count: 4, startingAt: 0)
        recorder.pause()

        var coordinate = walked.last
        var time = walked.lastTime
        for _ in 0..<30 {
            coordinate = coordinate.offset(bearingDegrees: 270, distanceM: 100)
            time += 60
            _ = recorder.consider(fix(coordinate, secondsIn: time),
                                  now: start.addingTimeInterval(time + 1))
        }
        // Three kilometres later it is still paused, because a person pressed
        // the button and only a person should un-press it.
        #expect(recorder.state == .paused(.manual))
    }

    // ---------- layer two: it pauses itself ----------

    @Test func `standing still long enough pauses the recording`() {
        var recorder = TrackRecorder()
        recorder.start()
        let walked = walk(&recorder, from: trailhead, count: 5, startingAt: 0)

        // Stopped at the summit. The filter rejects each fix as stationary,
        // and after two minutes of that the recorder draws the conclusion.
        var time = walked.lastTime
        var events: [RecorderEvent] = []
        for _ in 0..<6 {
            time += 30
            events.append(recorder.consider(fix(walked.last, secondsIn: time),
                                            now: start.addingTimeInterval(time + 1)))
        }

        #expect(events.contains(.autoPaused))
        #expect(recorder.state == .paused(.automatic))
        // Everything before the pause is still just rejected noise.
        #expect(recorder.track.segments.count == 1)
        #expect(recorder.track.gaps.isEmpty)
    }

    @Test func `an automatic pause ends itself and splices without asking`() {
        var recorder = TrackRecorder()
        recorder.start()
        let walked = walk(&recorder, from: trailhead, count: 5, startingAt: 0)

        var time = walked.lastTime
        for _ in 0..<6 {
            time += 30
            _ = recorder.consider(fix(walked.last, secondsIn: time),
                                  now: start.addingTimeInterval(time + 1))
        }
        #expect(recorder.state == .paused(.automatic))

        // Walking again. The recorder paused itself off a guess, so undoing
        // that guess is its own job — no prompt, no gap.
        var coordinate = walked.last
        var events: [RecorderEvent] = []
        for _ in 0..<3 {
            coordinate = coordinate.offset(bearingDegrees: 270, distanceM: 60)
            time += 30
            events.append(recorder.consider(fix(coordinate, secondsIn: time),
                                            now: start.addingTimeInterval(time + 1)))
        }

        #expect(events.contains { if case .autoResumed = $0 { return true } else { return false } })
        #expect(recorder.state == .recording)
        #expect(recorder.track.gaps.isEmpty)
        #expect(recorder.pendingRecovery == nil)
        #expect(recorder.track.recoveredPointCount > 0)
    }

    @Test func `a short stop does not trip the automatic pause`() {
        var recorder = TrackRecorder()
        recorder.start()
        let walked = walk(&recorder, from: trailhead, count: 5, startingAt: 0)

        // Ninety seconds reading a map, under the two-minute threshold.
        var time = walked.lastTime
        for _ in 0..<3 {
            time += 30
            #expect(recorder.consider(fix(walked.last, secondsIn: time),
                                      now: start.addingTimeInterval(time + 1))
                    == .ignored(.notMovedFarEnough))
        }
        #expect(recorder.state == .recording)
    }

    @Test func `the auto-pause threshold is measured from the last accepted fix`() {
        // Not from a fix count, so it behaves the same whether fixes arrive
        // every second or every half minute.
        var recorder = TrackRecorder(autoPauseAfterS: 60)
        recorder.start()
        let walked = walk(&recorder, from: trailhead, count: 3, startingAt: 0)

        // One stationary fix, 61 s after the last accepted one. A counter
        // would still be waiting for its quota.
        let event = recorder.consider(
            fix(walked.last, secondsIn: walked.lastTime + 61),
            now: start.addingTimeInterval(walked.lastTime + 62)
        )
        #expect(event == .autoPaused)
    }

    // ---------- stopping ----------

    @Test func `stopping during a pause ends the track without a trailing gap`() {
        var recorder = TrackRecorder()
        recorder.start()
        walk(&recorder, from: trailhead, count: 5, startingAt: 0)
        recorder.pause()
        recorder.stop()

        #expect(recorder.state == .stopped)
        #expect(recorder.track.gaps.isEmpty)
        #expect(recorder.track.segments.count == 1)
        #expect(recorder.state.wantsLocation == false)
    }

    @Test func `fixes after stopping are not recorded`() {
        var recorder = TrackRecorder()
        recorder.start()
        let walked = walk(&recorder, from: trailhead, count: 4, startingAt: 0)
        recorder.stop()
        let before = recorder.track.stats.measuredMiles

        let onwards = walked.last.offset(bearingDegrees: 270, distanceM: 200)
        #expect(recorder.consider(fix(onwards, secondsIn: walked.lastTime + 60),
                                  now: start.addingTimeInterval(walked.lastTime + 61))
                == .notRecording)
        #expect(recorder.track.stats.measuredMiles == before)
    }

    @Test func `the location stream stays up while paused`() {
        // The one state that looks like it should release the GPS and must
        // not: holding it is what makes a forgotten pause recoverable.
        #expect(TrackRecorder.State.paused(.manual).wantsLocation)
        #expect(TrackRecorder.State.paused(.automatic).wantsLocation)
        #expect(TrackRecorder.State.recording.wantsLocation)
        #expect(TrackRecorder.State.idle.wantsLocation == false)
        #expect(TrackRecorder.State.stopped.wantsLocation == false)
    }

    @Test func `starting again clears the previous session's state`() {
        var recorder = TrackRecorder()
        recorder.start()
        walk(&recorder, from: trailhead, count: 4, startingAt: 0)
        recorder.pause()
        recorder.start()

        #expect(recorder.state == .recording)
        #expect(recorder.pendingRecovery == nil)
    }

    // ---------- the filter is still in front of everything ----------

    @Test func `a bad fix is rejected before it can reach the track`() {
        var recorder = TrackRecorder()
        recorder.start()
        _ = recorder.consider(fix(trailhead, secondsIn: 0), now: start.addingTimeInterval(1))

        let far = trailhead.offset(bearingDegrees: 90, distanceM: 400)
        #expect(recorder.consider(fix(far, accuracy: 45, secondsIn: 60),
                                  now: start.addingTimeInterval(61))
                == .ignored(.tooInaccurate))
        #expect(recorder.track.segments[0].points.count == 1)
    }
}
