import Foundation
import GRDB

/// Proactive messages (`inbox_messages`): briefs, wraps, nudges and reminder firings.
///
/// Inserts take the caller's `Database`: delivery inserts the message and its chat turn in one
/// `DataGeneration.write` (GRDB writes are not reentrant). Bodies are model or user text: never log them.
public struct InboxStore: Sendable {
    private let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    /// Inserts `m` unless a message with its `dedupe_key` exists. Returns the stored row, or nil.
    public func insertIfNew(_ m: InboxMessage, in d: Database) throws -> InboxMessage? {
        try Self.insertIfNew(m, in: d)
    }

    public static func insertIfNew(_ m: InboxMessage, in d: Database) throws -> InboxMessage? {
        let exists = try Bool.fetchOne(d, sql: "SELECT 1 FROM inbox_messages WHERE dedupe_key = ?",
                                       arguments: [m.dedupeKey]) ?? false
        guard !exists else { return nil }
        var row = m
        row.id = nil
        try row.insert(d)
        return row
    }

    /// Inserts a nudge only when, checked inside this same write, fewer than `dailyCap` nudges were
    /// created since `dayStart` and the last nudge is at least `minGap` before `m.createdAt` (and
    /// its `dedupe_key` is new). Two racing scans therefore never exceed the cap. Returns the row, or
    /// nil (also for a message whose kind is not `.nudge`).
    ///
    /// The nudge's time is also appended to the nudge log (`nudgeLogKey`, times only), which
    /// "Clear chat" does not empty, so clearing the chat never resets the cap or the gap.
    public func insertNudge(_ m: InboxMessage, dailyCap: Int, minGap: TimeInterval, dayStart: Date,
                            in d: Database) throws -> InboxMessage? {
        guard m.kind == .nudge else { return nil }
        guard try Self.nudgeCount(since: dayStart, in: d) < dailyCap else { return nil }
        if let last = try Self.lastNudgeAt(in: d), m.createdAt.timeIntervalSince(last) < minGap { return nil }
        guard let stored = try Self.insertIfNew(m, in: d) else { return nil }
        let kept = try Self.nudgeLog(in: d).filter { $0 >= m.createdAt.addingTimeInterval(-Self.nudgeLogSpan) }
        try SettingsStore.store(try SettingsStore.json((kept + [m.createdAt]).sorted()), forKey: Self.nudgeLogKey, in: d)
        return stored
    }

    /// The times of recent nudges (JSON `[Date]`, a setting): what the daily cap and the gap count,
    /// together with the nudges still in the inbox. Times only, no content.
    public static let nudgeLogKey = "assistant.nudgeLog"
    /// Entries older than this (before the newest nudge) are dropped.
    static let nudgeLogSpan: TimeInterval = 2 * 86_400

    static func nudgeLog(in d: Database) throws -> [Date] {
        try SettingsStore.jsonValue([Date].self, forKey: nudgeLogKey, in: d) ?? []
    }

    public func nudgeCount(since: Date) throws -> Int {
        try db.reader.read { try Self.nudgeCount(since: since, in: $0) }
    }

    public func lastNudgeAt() throws -> Date? {
        try db.reader.read { try Self.lastNudgeAt(in: $0) }
    }

    /// Nudges since `since`: the larger of the inbox's count and the nudge log's (a cleared chat
    /// leaves only the log).
    static func nudgeCount(since: Date, in d: Database) throws -> Int {
        let inbox = try Int.fetchOne(d, sql: "SELECT count(*) FROM inbox_messages WHERE kind = 'nudge' AND created_at >= ?",
                                     arguments: [since]) ?? 0
        return max(inbox, try nudgeLog(in: d).filter { $0 >= since }.count)
    }

    /// The latest nudge in the inbox or the nudge log.
    static func lastNudgeAt(in d: Database) throws -> Date? {
        let inbox = try Date.fetchOne(d, sql: "SELECT max(created_at) FROM inbox_messages WHERE kind = 'nudge'")
        return ([inbox].compactMap { $0 } + (try nudgeLog(in: d))).max()
    }

    public func unseenCount() throws -> Int {
        try db.reader.read { d in
            try Int.fetchOne(d, sql: "SELECT count(*) FROM inbox_messages WHERE seen_at IS NULL") ?? 0
        }
    }

    /// Stamps `seen_at` on the messages not seen yet (the first time seen is kept).
    public func markSeen(_ ids: [Int64], at: Date) throws {
        guard !ids.isEmpty else { return }
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        var arguments: StatementArguments = [at]
        arguments += StatementArguments(ids)
        try db.writer.write { d in
            try d.execute(sql: "UPDATE inbox_messages SET seen_at = ? WHERE seen_at IS NULL AND id IN (\(marks))",
                          arguments: arguments)
        }
    }

    /// Records that a macOS notification was posted for the message.
    public func setNotified(_ id: Int64) throws {
        try db.writer.write { d in
            try d.execute(sql: "UPDATE inbox_messages SET notified = 1 WHERE id = ?", arguments: [id])
        }
    }
}
