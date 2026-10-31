import Foundation

/// Which source answered, when, and whether it was cached or stale.
///
/// Every provider reports here and the UI renders it. The point is being able
/// to tell a bad source from a bad mapping: a number with no origin is a
/// number you cannot debug in the field.
public struct ProvenanceRecord: Sendable, Equatable, Identifiable {
    /// The dataset, not the provider — "Elevation", "Trailheads", "Slope".
    /// One record per dataset, replaced on each fetch.
    public var dataset: String
    public var provider: String
    public var detail: String
    public var at: Date
    /// The source failed and this is the last good answer.
    public var isStale: Bool
    public var fromCache: Bool

    public var id: String { dataset }

    public init(
        dataset: String,
        provider: String,
        detail: String = "",
        at: Date = Date(),
        isStale: Bool = false,
        fromCache: Bool = false
    ) {
        self.dataset = dataset
        self.provider = provider
        self.detail = detail
        self.at = at
        self.isStale = isStale
        self.fromCache = fromCache
    }
}

/// Collects the most recent record per dataset, newest first.
///
/// An actor because providers report from whatever context they happen to run
/// on, and the web app's module-level Map plus listener Set is exactly the
/// shared mutable state Swift will not let you keep.
public actor ProvenanceLog {
    private var records: [String: ProvenanceRecord] = [:]

    public init() {}

    public func record(_ record: ProvenanceRecord) {
        records[record.dataset] = record
    }

    /// Newest first, matching the web app's sidebar order.
    public var all: [ProvenanceRecord] {
        records.values.sorted { $0.at > $1.at }
    }

    public func clear() {
        records.removeAll()
    }
}

extension ProvenanceRecord {
    /// Coarse relative age. Deliberately vague past the first minute: the
    /// question in the field is "is this fresh or is this yesterday", never
    /// "is this 7 or 8 minutes old".
    public static func ago(from date: Date, now: Date = Date()) -> String {
        let seconds = max(0, (now.timeIntervalSince(date)).rounded())
        if seconds < 45 { return "just now" }

        let minutes = (seconds / 60).rounded()
        if minutes < 60 { return "\(Int(minutes))m ago" }

        let hours = (minutes / 60).rounded()
        if hours < 24 { return "\(Int(hours))h ago" }

        let days = (hours / 24).rounded()
        if days < 30 { return "\(Int(days))d ago" }

        return "\(Int((days / 30).rounded()))mo ago"
    }

    public var ageDescription: String { Self.ago(from: at) }
}
