import Foundation

// Where recordings live.
//
// The requirement that shapes this file is not "save the track when the user
// taps stop" — it is "the phone died four hours into a hike". iOS kills
// backgrounded apps, batteries run out, and a recording held in memory until
// the end is a recording that can be lost in its entirety at the worst
// possible moment.
//
// So a recording is appended to a journal as it happens, one line per
// accepted fix, and only becomes a finished track at the end. A crash leaves
// a journal; the next launch finds it and offers the hike back.
//
// Not in the Caches directory, deliberately. `ProviderCache` lives there and
// enforces a byte budget by evicting the oldest files, and iOS may purge the
// whole directory under storage pressure. Both are correct for tiles and
// elevation samples, which can be fetched again, and catastrophic for the
// only copy of somebody's hike.

/// One line of the journal.
///
/// An enum rather than a dictionary so a line that cannot be understood is a
/// decode failure on that line alone, not a silently ignored key.
enum JournalEntry: Codable, Sendable, Equatable {
    case started(name: String, at: Date)
    case point(lon: Double, lat: Double, at: Date)
    /// The recording stopped; the next point begins a new segment.
    case broke(cause: GapCause)
}

/// What the list needs, without decoding a hike's worth of points.
///
/// Written beside each track as its own small file. An index file holding all
/// of them would be one more thing to keep in step with the directory, and
/// the failure mode — an index that disagrees with what is on disk — is worse
/// than the thing it optimises.
public struct TrackSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var startedAt: Date
    public var miles: Double
    public var gainFeet: Double
    public var elapsedSeconds: Double
    public var gapCount: Int
    /// The total leans on an estimate, so a list can say so without opening
    /// the track.
    public var hasEstimate: Bool

    init(id: UUID, track: Track) {
        let stats = track.stats
        self.id = id
        self.name = track.name
        self.startedAt = track.firstPoint?.timestamp ?? Date(timeIntervalSince1970: 0)
        self.miles = stats.totalMiles
        self.gainFeet = stats.totalGainFeet
        self.elapsedSeconds = stats.elapsedSeconds
        self.gapCount = track.gaps.count
        self.hasEstimate = stats.hasEstimate
    }
}

public actor TrackStore {
    private let directory: URL
    private let journalURL: URL
    /// Held open for the life of a recording. Reopening per fix would mean a
    /// path lookup and a file open every thirty seconds for the length of a
    /// hike.
    private var journal: FileHandle?

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Karta/Tracks", isDirectory: true)
        self.directory = base
        self.journalURL = base.appendingPathComponent("current.journal")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    // ---------- the live journal ----------

    /// Starts a journal, replacing any previous one.
    ///
    /// Call only once the old journal has been recovered or discarded — this
    /// truncates.
    public func beginJournal(name: String, at date: Date) {
        closeJournal()
        FileManager.default.createFile(atPath: journalURL.path, contents: nil)
        journal = try? FileHandle(forWritingTo: journalURL)
        append(.started(name: name, at: date))
    }

    /// Internal because `JournalEntry` is: the file format is this type's
    /// own business, and callers say what happened, not how it is written.
    func append(_ entry: JournalEntry) {
        guard let journal, let data = try? JSONEncoder().encode(entry) else { return }
        // One JSON object per line. A half-written final line is the expected
        // shape of a crash, and replay drops it without taking the rest of
        // the hike with it.
        try? journal.write(contentsOf: data + Data("\n".utf8))
    }

    public func appendBreak(cause: GapCause) {
        append(.broke(cause: cause))
    }

    public func appendPoint(_ point: TrackPoint) {
        append(.point(lon: point.coordinate.longitude,
                      lat: point.coordinate.latitude,
                      at: point.timestamp))
    }

    private func closeJournal() {
        try? journal?.close()
        journal = nil
    }

    /// True when a recording was interrupted rather than stopped.
    public var hasUnfinishedRecording: Bool {
        FileManager.default.fileExists(atPath: journalURL.path)
    }

    /// Rebuilds whatever the journal holds.
    ///
    /// Returns nil for a journal with no points — a recording started and
    /// killed before the first fix has nothing in it to offer back.
    public func recoverJournal() -> Track? {
        guard let text = try? String(contentsOf: journalURL, encoding: .utf8) else { return nil }

        var track = Track()
        var pendingBreak = false
        var points = 0

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            // A trailing partial line is what a crash mid-write looks like.
            // Skipping it is the whole reason for a line-delimited format.
            guard let entry = try? JSONDecoder().decode(
                JournalEntry.self, from: Data(line.utf8)) else { continue }

            switch entry {
            case .started(let name, _):
                track.name = name
            case .point(let lon, let lat, let at):
                let point = TrackPoint(
                    coordinate: Coordinate(longitude: lon, latitude: lat), timestamp: at)
                if pendingBreak {
                    track.resume(at: point)
                    pendingBreak = false
                } else {
                    track.append(point)
                }
                points += 1
            case .broke(let cause):
                track.markBreak(cause: cause)
                pendingBreak = true
            }
        }

        return points > 0 ? track : nil
    }

    public func discardJournal() {
        closeJournal()
        try? FileManager.default.removeItem(at: journalURL)
    }

    // ---------- finished tracks ----------

    /// Writes the track and drops the journal, in that order.
    ///
    /// If the write fails the journal survives, so the next launch still
    /// offers the hike. Deleting first and then failing to write would lose
    /// it on the one path that is supposed to be safe.
    @discardableResult
    public func save(_ track: Track, id: UUID = UUID()) -> TrackSummary? {
        let summary = TrackSummary(id: id, track: track)
        guard let trackData = try? JSONEncoder().encode(track),
              let summaryData = try? JSONEncoder().encode(summary),
              (try? trackData.write(to: url(for: id), options: .atomic)) != nil,
              (try? summaryData.write(to: summaryURL(for: id), options: .atomic)) != nil
        else { return nil }

        discardJournal()
        return summary
    }

    /// Newest first, which is the order anybody looks for a hike in.
    public func list() -> [TrackSummary] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []

        return files
            .filter { $0.lastPathComponent.hasSuffix(".meta.json") }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(TrackSummary.self, from: data)
            }
            .sorted { $0.startedAt > $1.startedAt }
    }

    public func load(_ id: UUID) -> Track? {
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        return try? JSONDecoder().decode(Track.self, from: data)
    }

    public func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
        try? FileManager.default.removeItem(at: summaryURL(for: id))
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func summaryURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).meta.json")
    }
}
