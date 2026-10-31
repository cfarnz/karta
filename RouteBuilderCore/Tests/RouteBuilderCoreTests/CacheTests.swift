import Foundation
import Testing
@testable import RouteBuilderCore

/// Each test gets its own directory under the system temp dir, so they can run
/// in parallel without stepping on each other's files.
private func tempCache(maxPoints: Int = ProviderCache.defaultMaxPoints) -> (ProviderCache, URL) {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("rb-cache-test-\(UUID().uuidString)", isDirectory: true)
    return (ProviderCache(directory: dir, maxPoints: maxPoints), dir)
}

private struct Payload: Codable, Sendable, Equatable {
    var label: String
    var count: Int
}

private struct Boom: Error {}

@Suite("Provider cache")
struct ProviderCacheTests {

    @Test func `a miss fetches and reports it did not come from cache`() async throws {
        let (cache, dir) = tempCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let hit = try await cache.cached(key: "weather:boulder", ttl: TTL.weather) {
            Payload(label: "fresh", count: 1)
        }
        #expect(hit.value == Payload(label: "fresh", count: 1))
        #expect(hit.fromCache == false)
        #expect(hit.isStale == false)
    }

    @Test func `a fresh hit short-circuits the fetcher entirely`() async throws {
        let (cache, dir) = tempCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try await cache.cached(key: "k", ttl: TTL.weather) { Payload(label: "first", count: 1) }

        let hit = try await cache.cached(key: "k", ttl: TTL.weather) {
            Issue.record("fetcher ran despite a fresh cache entry")
            return Payload(label: "second", count: 2)
        }
        #expect(hit.value.label == "first")
        #expect(hit.fromCache)
    }

    @Test func `an expired entry is refetched`() async throws {
        let (cache, dir) = tempCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try await cache.cached(key: "k", ttl: TTL.weather) { Payload(label: "old", count: 1) }
        // A zero TTL makes anything already written expired.
        let hit = try await cache.cached(key: "k", ttl: 0) { Payload(label: "new", count: 2) }
        #expect(hit.value.label == "new")
        #expect(hit.fromCache == false)
    }

    // The behaviour the whole cache exists for: when a source goes down, the
    // last good answer beats an error — as long as it is labelled stale so the
    // UI can say how old it is.
    @Test func `a failed fetch falls back to the last good answer, marked stale`() async throws {
        let (cache, dir) = tempCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try await cache.cached(key: "avy", ttl: TTL.avalanche) {
            Payload(label: "bulletin", count: 3)
        }

        let hit: CacheHit<Payload> = try await cache.cached(key: "avy", ttl: 0) {
            throw Boom()
        }
        #expect(hit.value.label == "bulletin")
        #expect(hit.isStale)
        #expect(hit.fromCache)
    }

    @Test func `a failed fetch with nothing cached rethrows`() async throws {
        let (cache, dir) = tempCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        await #expect(throws: Boom.self) {
            let _: CacheHit<Payload> = try await cache.cached(key: "cold", ttl: 0) {
                throw Boom()
            }
        }
    }

    @Test func `keys with punctuation survive the round trip to disk`() async throws {
        let (cache, dir) = tempCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Real key shapes from the web app: colons, commas, dots, minus signs.
        let key = "trailheads:-105.28,39.99:25"
        _ = try await cache.cached(key: key, ttl: TTL.trailheads) {
            Payload(label: "chautauqua", count: 42)
        }
        let hit = try await cache.cached(key: key, ttl: TTL.trailheads) {
            Payload(label: "wrong", count: 0)
        }
        #expect(hit.value.label == "chautauqua")
        #expect(hit.fromCache)
    }

    @Test func `distinct keys do not collide`() async throws {
        let (cache, dir) = tempCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try await cache.cached(key: "a:1", ttl: TTL.weather) { Payload(label: "a", count: 1) }
        _ = try await cache.cached(key: "a:2", ttl: TTL.weather) { Payload(label: "b", count: 2) }

        let first = try await cache.cached(key: "a:1", ttl: TTL.weather) { Payload(label: "x", count: 0) }
        #expect(first.value.label == "a")
    }
}

@Suite("Elevation point cache")
struct PointCacheTests {

    @Test func `points round-trip through a flush and a fresh instance`() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rb-points-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = ProviderCache(directory: dir)
        await first.setPoints(["-1052811,399992": 1760.0, "-1052928,399865": 2100.0])
        await first.flushPoints()

        // A second instance reads what the first wrote — the cache survives a
        // relaunch, which is the point of moving off localStorage.
        let second = ProviderCache(directory: dir)
        #expect(await second.point("-1052811,399992") == 1760.0)
        #expect(await second.point("-1052928,399865") == 2100.0)
        #expect(await second.point("missing") == nil)
    }

    @Test func `bulk lookup returns only the keys it holds`() async throws {
        let (cache, dir) = tempCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        await cache.setPoints(["a": 1, "b": 2, "c": 3])
        let found = await cache.points(["a", "c", "nope"])
        #expect(found == ["a": 1, "c": 3])
    }

    @Test func `the oldest points fall off first once the ceiling is hit`() async throws {
        let (cache, dir) = tempCache(maxPoints: 10)
        defer { try? FileManager.default.removeItem(at: dir) }

        for i in 0..<10 { await cache.setPoints(["p\(i)": Double(i)]) }
        #expect(await cache.point("p0") == 0)

        // Five more pushes the five earliest out, insertion-ordered.
        for i in 10..<15 { await cache.setPoints(["p\(i)": Double(i)]) }

        #expect(await cache.point("p0") == nil)
        #expect(await cache.point("p4") == nil)
        #expect(await cache.point("p5") == 5)
        #expect(await cache.point("p14") == 14)
        #expect(await cache.stats().points == 10)
    }

    @Test func `rewriting an existing point does not consume a new slot`() async throws {
        let (cache, dir) = tempCache(maxPoints: 3)
        defer { try? FileManager.default.removeItem(at: dir) }

        await cache.setPoints(["a": 1, "b": 2, "c": 3])
        await cache.setPoints(["a": 99])  // an update, not an insertion

        #expect(await cache.point("a") == 99)
        #expect(await cache.point("b") == 2)
        #expect(await cache.stats().points == 3)
    }

    @Test func `clear empties both caches`() async throws {
        let (cache, dir) = tempCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try await cache.cached(key: "k", ttl: TTL.weather) { Payload(label: "v", count: 1) }
        await cache.setPoints(["a": 1])
        await cache.flushPoints()

        await cache.clear()
        #expect(await cache.point("a") == nil)
        #expect(await cache.stats().entries == 0)
    }
}

@Suite("Provenance")
struct ProvenanceTests {

    @Test(arguments: [
        (0.0, "just now"),
        (44.0, "just now"),
        (60.0, "1m ago"),
        (600.0, "10m ago"),
        (3600.0, "1h ago"),
        (7200.0, "2h ago"),
        (86_400.0, "1d ago"),
        (5 * 86_400.0, "5d ago"),
        (60 * 86_400.0, "2mo ago"),
    ])
    func `relative ages read the way the sidebar expects`(secondsAgo: Double, expected: String) {
        let now = Date()
        #expect(ProvenanceRecord.ago(from: now.addingTimeInterval(-secondsAgo), now: now) == expected)
    }

    @Test func `a future timestamp does not read as negative`() {
        let now = Date()
        #expect(ProvenanceRecord.ago(from: now.addingTimeInterval(600), now: now) == "just now")
    }

    @Test func `the log keeps one record per dataset, newest first`() async {
        let log = ProvenanceLog()
        let now = Date()

        await log.record(.init(dataset: "Elevation", provider: "Open-Meteo",
                               at: now.addingTimeInterval(-120)))
        await log.record(.init(dataset: "Trailheads", provider: "OSM Overpass",
                               at: now.addingTimeInterval(-60)))
        // A second Elevation fetch replaces the first rather than stacking.
        await log.record(.init(dataset: "Elevation", provider: "USGS 3DEP", at: now))

        let all = await log.all
        #expect(all.count == 2)
        #expect(all.first?.dataset == "Elevation")
        #expect(all.first?.provider == "USGS 3DEP")
    }
}
