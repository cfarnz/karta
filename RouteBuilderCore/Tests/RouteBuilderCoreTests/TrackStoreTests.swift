import Testing
import Foundation
@testable import RouteBuilderCore

// Every test gets its own directory. The store's real home is Application
// Support, and a test that wrote there would leave somebody's actual hikes
// next to its fixtures.

private let trailhead = Coordinate(longitude: -106.4752, latitude: 39.1875)  // Mt Massive
private let start = Date(timeIntervalSince1970: 1_762_000_000)

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("karta-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func point(_ coordinate: Coordinate, secondsIn: Double) -> TrackPoint {
    TrackPoint(coordinate: coordinate, timestamp: start.addingTimeInterval(secondsIn))
}

/// A walk west, one point every 30 s.
private func walk(count: Int, from origin: Coordinate = trailhead,
                  startingAt secondsIn: Double = 0) -> [TrackPoint] {
    var coordinate = origin
    var out: [TrackPoint] = []
    for i in 0..<count {
        if i > 0 { coordinate = coordinate.offset(bearingDegrees: 270, distanceM: 45) }
        out.append(point(coordinate, secondsIn: secondsIn + Double(i) * 30))
    }
    return out
}

@Suite("Recordings survive the app dying")
struct TrackStoreTests {

    // ---------- the journal ----------

    @Test func `a journal replays into the track that was being recorded`() async {
        let store = TrackStore(directory: temporaryDirectory())
        await store.beginJournal(name: "Mt Massive", at: start)
        for p in walk(count: 10) { await store.appendPoint(p) }

        // Nothing called save: this is the app being killed mid-hike.
        #expect(await store.hasUnfinishedRecording)

        let recovered = await store.recoverJournal()
        #expect(recovered?.name == "Mt Massive")
        #expect(recovered?.segments.first?.points.count == 10)
        #expect(abs((recovered?.stats.measuredMiles ?? 0)
                    - 405 / Units.metersPerMile) < 1e-6)
    }

    @Test func `a break in the journal replays as a gap`() async {
        let store = TrackStore(directory: temporaryDirectory())
        await store.beginJournal(name: "Paused", at: start)
        for p in walk(count: 5) { await store.appendPoint(p) }
        await store.appendBreak(cause: .userPause)
        let onwards = trailhead.offset(bearingDegrees: 270, distanceM: 600)
        for p in walk(count: 5, from: onwards, startingAt: 600) { await store.appendPoint(p) }

        let recovered = await store.recoverJournal()
        #expect(recovered?.segments.count == 2)
        #expect(recovered?.gaps.count == 1)
        #expect(recovered?.gaps.first?.cause == .userPause)
    }

    @Test func `a half-written last line loses only itself`() async {
        let directory = temporaryDirectory()
        let store = TrackStore(directory: directory)
        await store.beginJournal(name: "Interrupted", at: start)
        for p in walk(count: 6) { await store.appendPoint(p) }

        // The shape of a crash mid-write: the process died with a partial
        // JSON object in the buffer. Line-delimited is the whole reason this
        // costs one fix rather than the hike.
        let url = directory.appendingPathComponent("current.journal")
        let truncated = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (truncated + #"{"point":{"lon":-106.4"#).write(
            to: url, atomically: true, encoding: .utf8)

        let recovered = await store.recoverJournal()
        #expect(recovered?.segments.first?.points.count == 6)
    }

    @Test func `a journal with no points offers nothing back`() async {
        let store = TrackStore(directory: temporaryDirectory())
        await store.beginJournal(name: "Started and killed", at: start)
        // Started, then killed before the first fix. There is no hike here to
        // hand back, and offering an empty one is worse than silence.
        #expect(await store.recoverJournal() == nil)
    }

    @Test func `starting a new journal replaces the old one`() async {
        let store = TrackStore(directory: temporaryDirectory())
        await store.beginJournal(name: "First", at: start)
        for p in walk(count: 4) { await store.appendPoint(p) }

        await store.beginJournal(name: "Second", at: start)
        await store.appendPoint(point(trailhead, secondsIn: 0))

        let recovered = await store.recoverJournal()
        #expect(recovered?.name == "Second")
        #expect(recovered?.segments.first?.points.count == 1)
    }

    // ---------- saving ----------

    @Test func `saving writes the track and clears the journal`() async {
        let store = TrackStore(directory: temporaryDirectory())
        await store.beginJournal(name: "Mt Massive", at: start)
        for p in walk(count: 8) { await store.appendPoint(p) }

        guard let track = await store.recoverJournal() else {
            Issue.record("expected a track to save")
            return
        }
        let summary = await store.save(track)

        #expect(summary?.name == "Mt Massive")
        // The journal is what "unfinished" means, so a saved hike must not
        // leave one behind to be offered back on the next launch.
        #expect(await store.hasUnfinishedRecording == false)
    }

    @Test func `a saved track reloads with its gaps and bridges intact`() async {
        let store = TrackStore(directory: temporaryDirectory())
        var track = Track(name: "Bridged")
        for p in walk(count: 4) { track.append(p) }
        track.markBreak(cause: .signalLoss)
        let onwards = trailhead.offset(bearingDegrees: 270, distanceM: 500)
        track.resume(at: point(onwards, secondsIn: 600))
        track.applyBridge(.straight, toGapAt: 0)

        let id = UUID()
        await store.save(track, id: id)
        let loaded = await store.load(id)

        #expect(loaded?.gaps.count == 1)
        #expect(loaded?.gaps.first?.bridge == .straight)
        #expect(loaded?.stats.estimatedMiles == track.stats.estimatedMiles)
    }

    @Test func `the list reads summaries without loading the points`() async {
        let store = TrackStore(directory: temporaryDirectory())
        var early = Track(name: "Yesterday")
        for p in walk(count: 5) { early.append(p) }
        var late = Track(name: "Today")
        for p in walk(count: 12, startingAt: 86_400) { late.append(p) }

        await store.save(early)
        await store.save(late)

        let list = await store.list()
        #expect(list.count == 2)
        // Newest first, which is the order anybody looks for a hike in.
        #expect(list.first?.name == "Today")
        #expect(list.first?.miles ?? 0 > list.last?.miles ?? 0)
    }

    @Test func `deleting takes the summary with it`() async {
        let store = TrackStore(directory: temporaryDirectory())
        let id = UUID()
        var track = Track(name: "Doomed")
        for p in walk(count: 4) { track.append(p) }
        await store.save(track, id: id)

        await store.delete(id)
        #expect(await store.list().isEmpty)
        // A summary left behind would show a hike in the list that cannot be
        // opened.
        #expect(await store.load(id) == nil)
    }

    @Test func `an empty store lists nothing rather than failing`() async {
        let store = TrackStore(directory: temporaryDirectory())
        #expect(await store.list().isEmpty)
        #expect(await store.hasUnfinishedRecording == false)
        #expect(await store.recoverJournal() == nil)
    }

    @Test func `summaries carry what the list shows`() async {
        let store = TrackStore(directory: temporaryDirectory())
        var track = Track(name: "Stats")
        for i in 0..<10 {
            var coordinate = trailhead.offset(bearingDegrees: 270, distanceM: Double(i) * 45)
            coordinate.elevation = 3_000 + Double(i) * 10
            track.append(point(coordinate, secondsIn: Double(i) * 30))
        }

        guard let summary = await store.save(track) else {
            Issue.record("expected a summary")
            return
        }
        #expect(summary.startedAt == start)
        #expect(abs(summary.gainFeet - 90 * Units.feetPerMeter) < 0.01)
        #expect(summary.elapsedSeconds == 270)
        #expect(summary.gapCount == 0)
        #expect(summary.hasEstimate == false)
    }
}
