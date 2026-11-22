import Foundation
import GRDB

public struct ActivityEvent: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var app: String
    public var bundleID: String?
    public var windowTitle: String?
    public var domain: String?
    public var startedAt: Date
    public var endedAt: Date

    public init(id: Int64? = nil, app: String, bundleID: String? = nil, windowTitle: String? = nil,
                domain: String? = nil, startedAt: Date, endedAt: Date) {
        self.id = id; self.app = app; self.bundleID = bundleID; self.windowTitle = windowTitle
        self.domain = domain; self.startedAt = startedAt; self.endedAt = endedAt
    }

    public static let databaseTableName = "activity_events"

    enum CodingKeys: String, CodingKey {
        case id, app
        case bundleID = "bundle_id"
        case windowTitle = "window_title"
        case domain
        case startedAt = "started_at"
        case endedAt = "ended_at"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct ActivityStore: Sendable {
    private let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    /// A gap longer than this between ticks (idle, locked, asleep, paused, hung app) is not
    /// focus time: the open event is left as is and a new one starts.
    public static let idleGap: TimeInterval = 30

    /// The open (most recently inserted) event: a rowid lookup, runs on every tick.
    static let openEventSQL = "SELECT * FROM activity_events ORDER BY id DESC LIMIT 1"
    /// Range on the v2 `ended_at` index.
    static let eventsSinceSQL = "SELECT * FROM activity_events WHERE ended_at >= ? ORDER BY started_at, id"

    public func recordFocus(app: String, bundleID: String?, windowTitle: String?,
                            domain: String?, at: Date) throws {
        try recordFocus(app: app, bundleID: bundleID, windowTitle: windowTitle, domain: domain,
                        at: at, unlessPausedAt: nil)
    }

    /// With `unlessPausedAt`, the pause check happens inside the same write transaction.
    /// Returns false when skipped because paused (or the pause value is corrupt).
    @discardableResult
    public func recordFocus(app: String, bundleID: String?, windowTitle: String?,
                            domain: String?, at: Date, unlessPausedAt now: Date?) throws -> Bool {
        try db.writer.write { d in
            if let now, try SettingsStore.isPausedFailClosed(d, now: now) { return false }
            var at = at
            if var last = try ActivityEvent.fetchOne(d, sql: Self.openEventSQL) {
                // Out-of-order (earlier) timestamps are clamped so intervals never overlap.
                at = max(at, last.endedAt)
                if at.timeIntervalSince(last.endedAt) <= Self.idleGap {
                    last.endedAt = at
                    try last.update(d)
                    if last.app == app, last.windowTitle == windowTitle, last.domain == domain {
                        return true
                    }
                }
            }
            var event = ActivityEvent(app: app, bundleID: bundleID, windowTitle: windowTitle,
                                      domain: domain, startedAt: at, endedAt: at)
            try event.insert(d)
            return true
        }
    }

    public func events(since: Date) throws -> [ActivityEvent] {
        try db.reader.read { d in
            try ActivityEvent.fetchAll(d, sql: Self.eventsSinceSQL, arguments: [since])
        }
    }

    /// Events overlapping `interval` (`started_at < end AND ended_at > start`), oldest first. They
    /// are not clipped to it.
    public func events(overlapping interval: DateInterval) throws -> [ActivityEvent] {
        try db.reader.read { d in
            try ActivityEvent.fetchAll(d, sql: """
                SELECT * FROM activity_events WHERE started_at < ? AND ended_at > ? ORDER BY started_at, id
                """, arguments: [interval.end, interval.start])
        }
    }

    /// Focus time inside `interval` per (app, bundle id, window title, domain), summed in SQL with
    /// each event clipped to the interval: a month or a year never loads its events one by one.
    /// Groups keep every field a capture policy judges, so callers can filter them like events.
    public struct FocusTotal: Sendable, Equatable {
        public var app: String
        public var bundleID: String?
        public var windowTitle: String?
        public var domain: String?
        public var seconds: Double

        public init(app: String, bundleID: String?, windowTitle: String?, domain: String?, seconds: Double) {
            self.app = app; self.bundleID = bundleID; self.windowTitle = windowTitle; self.domain = domain
            self.seconds = seconds
        }
    }

    public func focusTotals(in interval: DateInterval) throws -> [FocusTotal] {
        try db.reader.read { d in
            try Row.fetchAll(d, sql: """
                SELECT app, bundle_id, window_title, domain,
                       SUM((julianday(MIN(ended_at, ?)) - julianday(MAX(started_at, ?))) * 86400.0) AS seconds
                FROM activity_events WHERE started_at < ? AND ended_at > ?
                GROUP BY app, bundle_id, window_title, domain
                ORDER BY app, bundle_id, window_title, domain
                """, arguments: [interval.end, interval.start, interval.end, interval.start])
                .compactMap { row in
                    // julianday is a double: round to the millisecond.
                    let seconds = ((row["seconds"] as Double? ?? 0) * 1_000).rounded() / 1_000
                    guard seconds > 0 else { return nil }
                    return FocusTotal(app: row["app"], bundleID: row["bundle_id"], windowTitle: row["window_title"],
                                      domain: row["domain"], seconds: seconds)
                }
        }
    }

    /// Removes every activity event (used by "Delete all data").
    public func deleteAll() throws {
        try db.writer.write { d in _ = try ActivityEvent.deleteAll(d) }
    }
}
