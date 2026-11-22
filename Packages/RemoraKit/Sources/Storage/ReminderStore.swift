import Foundation
import GRDB

/// User reminders (`reminders`). The reminder engine (plan 5 Task 2) computes `next_fire_at`
/// and updates rows inside its own write (`update(_:in:)`, `due(at:in:)`). Texts are user text:
/// never log them.
public struct ReminderStore: Sendable {
    private let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    /// Inserts `r` and returns it with its id.
    @discardableResult
    public func insert(_ r: Reminder) throws -> Reminder {
        try db.writer.write { try insert(r, in: $0) }
    }

    @discardableResult
    public func insert(_ r: Reminder, in d: Database) throws -> Reminder {
        var row = r
        row.id = nil
        try row.insert(d)
        return row
    }

    public func update(_ r: Reminder, in d: Database) throws {
        try r.update(d)
    }

    public func get(_ id: Int64) throws -> Reminder? {
        try db.reader.read { try get(id, in: $0) }
    }

    public func get(_ id: Int64, in d: Database) throws -> Reminder? {
        try Reminder.fetchOne(d, key: id)
    }

    /// Active reminders, soonest `next_fire_at` first (unscheduled last).
    public func active() throws -> [Reminder] {
        try db.reader.read { try active(in: $0) }
    }

    public func active(in d: Database) throws -> [Reminder] {
        try Reminder.fetchAll(d, sql: """
            SELECT * FROM reminders WHERE status = 'active'
            ORDER BY next_fire_at IS NULL, next_fire_at, id
            """)
    }

    /// Active reminders with `next_fire_at <= at`, oldest due first.
    public func due(at: Date) throws -> [Reminder] {
        try db.reader.read { try due(at: at, in: $0) }
    }

    public func due(at: Date, in d: Database) throws -> [Reminder] {
        try Reminder.fetchAll(d, sql: """
            SELECT * FROM reminders WHERE status = 'active' AND next_fire_at <= ?
            ORDER BY next_fire_at, id
            """, arguments: [at])
    }

    /// The earliest `next_fire_at` among active reminders.
    public func nextFireAt() throws -> Date? {
        try db.reader.read { d in
            try Date.fetchOne(d, sql: "SELECT min(next_fire_at) FROM reminders WHERE status = 'active'")
        }
    }

    public func setStatus(_ id: Int64, _ s: ReminderStatus) throws {
        try db.writer.write { d in
            try d.execute(sql: "UPDATE reminders SET status = ? WHERE id = ?", arguments: [s.rawValue, id])
        }
    }
}
