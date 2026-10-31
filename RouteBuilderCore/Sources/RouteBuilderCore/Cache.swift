import Foundation

/// Per-dataset shelf lives. Different data goes stale at wildly different
/// rates, and pretending otherwise means either hammering a rate-limited
/// source or showing yesterday's avalanche bulletin.
public enum TTL {
    public static let elevation: TimeInterval = 365 * 24 * 3600  // terrain does not move
    public static let trailheads: TimeInterval = 7 * 24 * 3600   // OSM edits land slowly
    public static let weather: TimeInterval = 3600
    public static let air: TimeInterval = 3600                   // CAMS publishes hourly
    public static let avalanche: TimeInterval = 3 * 3600         // CAIC's rough cadence
    public static let alerts: TimeInterval = 15 * 60             // warnings change fast
}

/// A value plus where it came from, so callers can report provenance rather
/// than silently guessing.
public struct CacheHit<Value: Sendable>: Sendable {
    public var value: Value
    public var fetchedAt: Date
    /// The source failed and this is the last good answer.
    public var isStale: Bool
    public var fromCache: Bool
}

/// Disk-backed provider cache with per-dataset TTLs, stale fallback, and
/// eviction.
///
/// The web app kept this in `localStorage`, which gave it a hard ~5 MB quota
/// and a synchronous API. On iOS the natural home is the Caches directory —
/// the OS may purge it under pressure, which is correct for data that is all
/// re-fetchable, and it keeps the app's backup size down.
public actor ProviderCache {
    private let directory: URL
    private let pointsFile: URL
    private let byteBudget: Int

    /// Elevation is looked up thousands of points at a time, so one blob beats
    /// thousands of files. Held in memory and flushed deliberately.
    private var points: [String: Double] = [:]
    /// Explicit insertion order. The web app leaned on JS object key order for
    /// FIFO eviction; Swift dictionaries have no order, so it is stated here.
    private var pointOrder: [String] = []
    private var pointsLoaded = false
    private var unflushedPoints = 0

    public static let defaultMaxPoints = 20_000
    private let maxPoints: Int
    /// Flush after this many new points. The web app re-serialised all 20,000
    /// on every batch of 100; batching the writes is most of the reason route
    /// sampling feels different.
    private static let flushThreshold = 500

    public init(
        directory: URL? = nil,
        byteBudget: Int = 48 * 1024 * 1024,
        maxPoints: Int = ProviderCache.defaultMaxPoints
    ) {
        let base = directory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("route-builder", isDirectory: true)
        self.directory = base
        self.pointsFile = base.appendingPathComponent("points-elevation.json")
        self.byteBudget = byteBudget
        self.maxPoints = maxPoints
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    // ---------- keyed TTL cache ----------

    private struct Envelope<Value: Codable & Sendable>: Codable, Sendable {
        var fetchedAt: Date
        var value: Value
    }

    private func url(for key: String) -> URL {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.")
        let safe = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
        return directory.appendingPathComponent("\(safe).json")
    }

    private func read<Value: Codable & Sendable>(_ key: String) -> Envelope<Value>? {
        guard let data = try? Data(contentsOf: url(for: key)) else { return nil }
        return try? JSONDecoder().decode(Envelope<Value>.self, from: data)
    }

    private func write<Value: Codable & Sendable>(_ key: String, _ envelope: Envelope<Value>) {
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        do {
            try data.write(to: url(for: key), options: .atomic)
        } catch {
            evictOldest(fraction: 0.25)
            try? data.write(to: url(for: key), options: .atomic)
        }
    }

    /// Fetch through the cache.
    ///
    /// A fresh hit short-circuits. A miss fetches and stores. A fetch failure
    /// with any prior value returns that value marked stale — the last good
    /// answer beats an error, as long as the UI says how old it is. A failure
    /// with nothing cached rethrows.
    public func cached<Value: Codable & Sendable>(
        key: String,
        ttl: TimeInterval,
        fetch: @Sendable () async throws -> Value
    ) async throws -> CacheHit<Value> {
        let existing: Envelope<Value>? = read(key)

        if let existing, Date().timeIntervalSince(existing.fetchedAt) < ttl {
            return CacheHit(value: existing.value, fetchedAt: existing.fetchedAt,
                            isStale: false, fromCache: true)
        }

        do {
            let value = try await fetch()
            let now = Date()
            write(key, Envelope(fetchedAt: now, value: value))
            return CacheHit(value: value, fetchedAt: now, isStale: false, fromCache: false)
        } catch {
            if let existing {
                return CacheHit(value: existing.value, fetchedAt: existing.fetchedAt,
                                isStale: true, fromCache: true)
            }
            throw error
        }
    }

    // ---------- point cache ----------

    private struct PointStore: Codable {
        var order: [String]
        var values: [String: Double]
    }

    private func loadPoints() {
        guard !pointsLoaded else { return }
        pointsLoaded = true
        guard let data = try? Data(contentsOf: pointsFile),
              let store = try? JSONDecoder().decode(PointStore.self, from: data)
        else { return }
        points = store.values
        pointOrder = store.order
    }

    public func point(_ key: String) -> Double? {
        loadPoints()
        return points[key]
    }

    /// Bulk lookup. One call instead of one per point, which matters when a
    /// route asks about several thousand at once.
    public func points(_ keys: [String]) -> [String: Double] {
        loadPoints()
        // Walk the query, not the cache: a route asks about a few thousand
        // keys against a store of up to 20,000, and filtering the store with
        // `keys.contains` would be quadratic.
        var out: [String: Double] = [:]
        out.reserveCapacity(keys.count)
        for key in keys {
            if let value = points[key] { out[key] = value }
        }
        return out
    }

    public func setPoints(_ fresh: [String: Double]) {
        loadPoints()
        for key in fresh.keys where points[key] == nil {
            pointOrder.append(key)
        }
        points.merge(fresh) { _, new in new }

        if pointOrder.count > maxPoints {
            let excess = pointOrder.count - maxPoints
            for key in pointOrder.prefix(excess) { points.removeValue(forKey: key) }
            pointOrder.removeFirst(excess)
        }

        unflushedPoints += fresh.count
        if unflushedPoints >= Self.flushThreshold { flushPoints() }
    }

    /// Persist the point cache. Call on background transition; otherwise it
    /// flushes itself every `flushThreshold` points.
    public func flushPoints() {
        guard pointsLoaded else { return }
        let store = PointStore(order: pointOrder, values: points)
        if let data = try? JSONEncoder().encode(store) {
            try? data.write(to: pointsFile, options: .atomic)
        }
        unflushedPoints = 0
    }

    // ---------- maintenance ----------

    private var cacheFiles: [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        )) ?? []
    }

    /// Drop the oldest fraction by modification date. Saved routes live
    /// outside this directory and are never touched.
    public func evictOldest(fraction: Double) {
        let dated = cacheFiles
            .filter { $0 != pointsFile }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast) }
            .sorted { $0.1 < $1.1 }

        let count = Int((Double(dated.count) * fraction).rounded(.up))
        for (url, _) in dated.prefix(count) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public struct Stats: Sendable, Equatable {
        public var entries: Int
        public var points: Int
        public var bytes: Int
    }

    public func stats() -> Stats {
        loadPoints()
        let files = cacheFiles
        let bytes = files.reduce(0) {
            $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return Stats(entries: files.count, points: points.count, bytes: bytes)
    }

    /// Trim to the byte budget if the Caches directory has grown past it.
    public func enforceBudget() {
        guard stats().bytes > byteBudget else { return }
        evictOldest(fraction: 0.25)
    }

    public func clear() {
        for url in cacheFiles { try? FileManager.default.removeItem(at: url) }
        points = [:]
        pointOrder = []
        pointsLoaded = false
        unflushedPoints = 0
    }
}
