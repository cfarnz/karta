import Foundation

// The recording session: the state machine that turns a stream of fixes into
// a Track.
//
// Two of its rules exist because of how people actually use a tracker, not
// because of anything about GPS:
//
// 1. A pause stops *counting*, not the GPS. Fixes keep arriving into a shadow
//    buffer at a coarse rate. So when somebody pauses at a creek, walks on,
//    and remembers twenty minutes later, the app does not have to estimate
//    the missing stretch — it has the actual path, and can offer it.
//
// 2. Standing still pauses the recording on its own. Human error mostly
//    disappears when the human is not in the loop, and the signal is already
//    there: a run of fixes the filter rejects as "not moved far enough" is
//    what stopped looks like.
//
// A gap, and the estimating that comes with it, is now the last resort rather
// than the first answer — it happens when the sky fails or the app dies, or
// when the user looks at a recovered stretch and says that is not where I
// went.

/// A stretch walked while the recording was paused, recovered from the shadow
/// buffer.
///
/// These points were measured, not estimated — they are only here because the
/// user had asked not to count them, which is a decision worth re-asking
/// rather than overriding.
public struct RecoveredStretch: Sendable, Equatable {
    /// The buffered points, not including the one the recording paused at.
    public var points: [TrackPoint]
    /// Measured from the pause point, not from the first buffered fix.
    ///
    /// The difference is the first stride, and it is not academic: this is
    /// the number in "you moved 300 yards while paused, include it?", and it
    /// has to equal what accepting actually adds to the track. Measuring
    /// inside the buffer alone understated a 276 m stretch as 230 m.
    public var distanceM: Double
    public var durationS: Double

    init(from origin: TrackPoint?, points: [TrackPoint]) {
        self.points = points
        let path = (origin.map { [$0] } ?? []) + points
        self.distanceM = path.map(\.coordinate).trackLengthM
        self.durationS = {
            guard let first = path.first, let last = path.last else { return 0 }
            return last.timestamp.timeIntervalSince(first.timestamp)
        }()
    }
}

/// What a considered fix did, so the UI can say something true without
/// inspecting the recorder's internals.
public enum RecorderEvent: Sendable, Equatable {
    /// Added to the track, with the distance it contributed.
    case recorded(distanceM: Double)
    /// Judged and discarded.
    case ignored(FixRejection)
    /// Kept in the shadow buffer while paused. Not on the track, not lost.
    case buffered
    /// Stationary long enough that the recorder paused itself.
    case autoPaused
    /// Movement after an automatic pause. The buffered stretch is spliced in
    /// without asking: the app paused itself, so it has no business making the
    /// user confirm its own guess.
    case autoResumed(recoveredM: Double)
    /// Resumed from a manual pause having moved. Needs an answer from the
    /// person who pressed pause.
    case recoveryAvailable(RecoveredStretch)
    /// The fix arrived when nothing was being recorded.
    case notRecording
}

public struct TrackRecorder: Sendable {

    public enum PauseKind: Sendable, Equatable {
        /// The user pressed pause.
        case manual
        /// The recorder noticed they had stopped.
        case automatic
    }

    public enum State: Sendable, Equatable {
        case idle
        case recording
        case paused(PauseKind)
        case stopped

        public var isRecording: Bool { self == .recording }
        public var isPaused: Bool {
            if case .paused = self { return true }
            return false
        }
        /// Running in some form, so the location stream should stay up —
        /// including while paused, which is the whole point.
        public var wantsLocation: Bool {
            switch self {
            case .recording, .paused: return true
            case .idle, .stopped: return false
            }
        }
    }

    // ---------- tuning ----------

    /// Stationary for this long and the recorder pauses itself.
    ///
    /// Two minutes is long enough not to fire at a map check or a gate, short
    /// enough that a lunch stop is not counted as moving time. It is measured
    /// from the last *accepted* fix, so it works at any fix cadence rather
    /// than assuming one.
    public var autoPauseAfterS: Double
    /// Movement needed to end an automatic pause.
    public var autoResumeM: Double

    private var filter: DistanceAccuracyTrackFilter
    /// The same filter again, for the paused stream.
    ///
    /// Deliberately not a coarser one. The cost of recording through a pause
    /// is the radio being on, which has already been paid the moment the
    /// pause keeps the stream up — thinning the points saves memory nobody
    /// is short of (a point is tens of bytes) and loses the fidelity that
    /// made recovery better than estimating in the first place. A coarse
    /// 50 m gate measured a 276 m stretch as 184 m, which is an estimate
    /// wearing a measurement's clothes. The real battery lever is the
    /// location manager's own accuracy and distance filter, which belongs at
    /// the app layer. A separate instance only because its last-accepted
    /// point is its own.
    private var shadowFilter: DistanceAccuracyTrackFilter

    public private(set) var state: State = .idle
    public private(set) var track: Track
    /// Set when a manual pause ends and the buffer shows real movement.
    /// Resolved by `acceptRecovery` or `discardRecovery`.
    public private(set) var pendingRecovery: RecoveredStretch?

    /// Points collected while paused. Never part of the track until spliced.
    private var shadow: [TrackPoint] = []
    /// Where the recording was when it paused, to measure movement against.
    private var pausedAt: TrackPoint?
    private var lastAcceptedAt: Date?

    public init(
        name: String = "Recording",
        filter: DistanceAccuracyTrackFilter = DistanceAccuracyTrackFilter(),
        autoPauseAfterS: Double = 120,
        autoResumeM: Double = TrackGap.meaningfulM
    ) {
        self.track = Track(name: name)
        self.filter = filter
        self.autoPauseAfterS = autoPauseAfterS
        self.autoResumeM = autoResumeM
        self.shadowFilter = filter
    }

    // ---------- control ----------

    public mutating func start() {
        state = .recording
        lastAcceptedAt = nil
        filter.reset()
        shadowFilter.reset()
        shadow = []
        pausedAt = nil
        pendingRecovery = nil
    }

    /// The user pressing pause. Keeps the location stream up on purpose.
    public mutating func pause() {
        guard state.isRecording else { return }
        beginPause(.manual)
    }

    /// The user pressing resume. Any movement in the buffer becomes a
    /// question rather than a silent edit either way.
    public mutating func resume() -> RecorderEvent {
        guard case .paused = state else { return .notRecording }
        let stretch = bufferedStretch()
        state = .recording
        shadowFilter.reset()

        guard let stretch, stretch.distanceM >= autoResumeM else {
            // Paused in one place and resumed in the same place. Nothing
            // happened, so the recording simply continues in the same
            // segment; the stationary time stays in elapsed, which is the
            // honest record of a rest.
            shadow = []
            pausedAt = nil
            return .recorded(distanceM: 0)
        }

        pendingRecovery = stretch
        return .recoveryAvailable(stretch)
    }

    /// Takes the recovered stretch as measured track.
    ///
    /// The points go into the open segment and the recording continues in it,
    /// so there is no gap at all — nothing was missing, it was only set
    /// aside. That is the difference between recovering a stretch and
    /// estimating one.
    public mutating func acceptRecovery() {
        guard let stretch = pendingRecovery else { return }
        for point in stretch.points { track.append(point) }
        track.recoveredPointCount += stretch.points.count
        clearBuffer()
    }

    /// Rejects it, which is the case a gap exists for: the buffer's coarse
    /// points are not where the user says they went, so the stretch becomes
    /// unknown rather than wrong.
    public mutating func discardRecovery() {
        guard pendingRecovery != nil else { return }
        track.markBreak(cause: .userPause)
        awaitingGapResume = true
        clearBuffer()
    }

    /// Swaps in a track built from this one — the elevation fill after a
    /// recording stops. Refused while recording, so a long DEM round trip
    /// cannot land on top of fixes that arrived while it was in flight.
    public mutating func replaceTrack(with track: Track) {
        guard state == .stopped else { return }
        self.track = track
    }

    public mutating func stop() {
        // A pause that never resumed is where the recording ended, not a gap:
        // a gap needs two ends and this has one.
        state = .stopped
        clearBuffer()
    }

    // ---------- the stream ----------

    public mutating func consider(_ fix: LocationFix, now: Date = Date()) -> RecorderEvent {
        switch state {
        case .idle, .stopped:
            return .notRecording

        case .recording:
            return considerWhileRecording(fix, now: now)

        case .paused(let kind):
            return considerWhilePaused(fix, kind: kind, now: now)
        }
    }

    private mutating func considerWhileRecording(
        _ fix: LocationFix,
        now: Date
    ) -> RecorderEvent {
        let decision = filter.consider(fix, now: now)

        switch decision {
        case .accepted(let distance):
            let point = TrackPoint(fix: fix)
            // A gap awaiting its far end closes here: the first fix after a
            // discarded recovery is the other side of it.
            if awaitingGapResume {
                track.resume(at: point)
                awaitingGapResume = false
            } else {
                track.append(point)
            }
            lastAcceptedAt = fix.timestamp
            return .recorded(distanceM: distance)

        case .rejected(let reason):
            // Stationary is the one rejection with a consequence beyond
            // dropping the fix.
            if reason == .notMovedFarEnough, shouldAutoPause(at: fix.timestamp) {
                beginPause(.automatic)
                // The fix that triggered the pause is the first evidence of
                // where they stopped, so it seeds the buffer rather than
                // being thrown away.
                seedShadow(with: fix)
                return .autoPaused
            }
            return .ignored(reason)
        }
    }

    private mutating func considerWhilePaused(
        _ fix: LocationFix,
        kind: PauseKind,
        now: Date
    ) -> RecorderEvent {
        // Judged by the same rules as the live track, so a recovered stretch
        // is as good as a recorded one.
        guard case .accepted = shadowFilter.consider(fix, now: now) else {
            return .buffered
        }
        shadow.append(TrackPoint(fix: fix))

        // Only an automatic pause ends itself. A manual one waits for the
        // person who started it, however far they walk.
        guard kind == .automatic,
              let paused = pausedAt,
              fix.coordinate.distance(to: paused.coordinate) >= autoResumeM
        else {
            return .buffered
        }

        let stretch = bufferedStretch()
        state = .recording
        shadowFilter.reset()
        // Spliced without asking. The recorder paused itself off a guess, so
        // reversing that guess is its own job, not the user's.
        for point in stretch?.points ?? [] { track.append(point) }
        track.recoveredPointCount += stretch?.points.count ?? 0
        lastAcceptedAt = fix.timestamp
        clearBuffer()
        return .autoResumed(recoveredM: stretch?.distanceM ?? 0)
    }

    // ---------- internals ----------

    /// Set by `discardRecovery` and cleared by the next accepted fix, which
    /// is the first moment the far end of the gap exists. The near end is
    /// already held by the track's own pending break.
    private var awaitingGapResume = false

    private func shouldAutoPause(at timestamp: Date) -> Bool {
        guard let last = lastAcceptedAt else { return false }
        return timestamp.timeIntervalSince(last) >= autoPauseAfterS
    }

    private mutating func beginPause(_ kind: PauseKind) {
        state = .paused(kind)
        pausedAt = track.lastPoint
        shadow = []
        shadowFilter.reset()
    }

    private mutating func seedShadow(with fix: LocationFix) {
        _ = shadowFilter.consider(fix)
        shadow = [TrackPoint(fix: fix)]
    }

    private func bufferedStretch() -> RecoveredStretch? {
        shadow.isEmpty ? nil : RecoveredStretch(from: pausedAt, points: shadow)
    }

    private mutating func clearBuffer() {
        shadow = []
        pausedAt = nil
        pendingRecovery = nil
    }
}
