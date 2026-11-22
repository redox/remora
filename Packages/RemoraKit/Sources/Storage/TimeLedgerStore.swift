import Foundation
import GRDB

/// Focus time per hour and (project, app, domain) (`time_ledger`), and the user's rules that
/// map activity to projects (`time_rules`).
///
/// The ledger is local bookkeeping: it may hold the names of apps excluded since (F-58); it never
/// goes into a prompt.
public struct TimeLedgerStore: Sendable {
    /// `replace(hour:rows:)` got a row of another hour.
    public struct HourMismatch: Error, Equatable { public init() {} }

    private let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    /// Replaces every row of `hour` with `rows` (all of which must start at `hour`). Running it
    /// again with the same rows changes nothing.
    public func replace(hour: Date, rows: [TimeLedgerRow], in d: Database) throws {
        guard rows.allSatisfy({ $0.hourStart == hour }) else { throw HourMismatch() }
        try d.execute(sql: "DELETE FROM time_ledger WHERE hour_start = ?", arguments: [hour])
        for var row in rows { try row.insert(d) }
    }

    /// Seconds per project for hours starting in `[from, to)`, most first (ties by name).
    public func report(from: Date, to: Date) throws -> [(project: String, seconds: Double)] {
        try db.reader.read { d in try report(from: from, to: to, in: d) }
    }

    public func report(from: Date, to: Date, in d: Database) throws -> [(project: String, seconds: Double)] {
        try Row.fetchAll(d, sql: """
            SELECT project, SUM(seconds) AS seconds FROM time_ledger
            WHERE hour_start >= ? AND hour_start < ?
            GROUP BY project ORDER BY seconds DESC, project
            """, arguments: [from, to])
            .map { (project: $0["project"], seconds: $0["seconds"]) }
    }

    /// Rows of hours starting in `[from, to)`, by hour then (project, app, domain).
    public func rows(from: Date, to: Date, in d: Database) throws -> [TimeLedgerRow] {
        try TimeLedgerRow.fetchAll(d, sql: """
            SELECT * FROM time_ledger WHERE hour_start >= ? AND hour_start < ?
            ORDER BY hour_start, project, app, domain
            """, arguments: [from, to])
    }

    /// Every rule, in id order (the order the matcher tries them).
    public func rules() throws -> [TimeRule] {
        try db.reader.read { d in try rules(in: d) }
    }

    public func rules(in d: Database) throws -> [TimeRule] {
        try TimeRule.fetchAll(d, sql: "SELECT * FROM time_rules ORDER BY id")
    }

    /// Stores a new rule and returns it with its id.
    @discardableResult
    public func addRule(_ r: TimeRule) throws -> TimeRule {
        try db.writer.write { d in
            var rule = r
            rule.id = nil
            try rule.insert(d)
            return rule
        }
    }

    public func removeRule(id: Int64) throws {
        try db.writer.write { d in _ = try TimeRule.deleteOne(d, key: id) }
    }
}
