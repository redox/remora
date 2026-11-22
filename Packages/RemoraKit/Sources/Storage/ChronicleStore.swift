import Foundation
import GRDB

/// Hour, day, week, month and year summaries (`chronicle`), one row per `(level, period_key)`.
///
/// Writes take the caller's `Database` so a runner can do them inside `DataGeneration.write`
/// (GRDB writes are not reentrant). Callers redact LLM output before storing it.
public struct ChronicleStore: Sendable {
    private let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    public func chronicle(_ level: ChronicleLevel, key: String) throws -> Chronicle? {
        try db.reader.read { d in try chronicle(level, key: key, in: d) }
    }

    public func chronicle(_ level: ChronicleLevel, key: String, in d: Database) throws -> Chronicle? {
        try Chronicle.fetchOne(d, sql: "SELECT * FROM chronicle WHERE level = ? AND period_key = ?",
                               arguments: [level.rawValue, key])
    }

    /// The chronicles one level down (hour for a day; day for a week or month; month for a year)
    /// whose period lies inside `c`'s, oldest first. An hour has none.
    public func children(of c: Chronicle) throws -> [Chronicle] {
        guard let level = c.level.childLevel else { return [] }
        return try db.reader.read { d in
            try chronicles(level, within: DateInterval(start: c.periodStart, end: c.periodEnd), in: d)
        }
    }

    /// Rows of `level` whose period lies inside `period`, oldest first (a rollup's children).
    public func chronicles(_ level: ChronicleLevel, within period: DateInterval, in d: Database) throws -> [Chronicle] {
        try Chronicle.fetchAll(d, sql: """
            SELECT * FROM chronicle WHERE level = ? AND period_start >= ? AND period_end <= ?
            ORDER BY period_start, id
            """, arguments: [level.rawValue, period.start, period.end])
    }

    /// The row of `level` whose period contains all of `interval` (for an hour: the hour's own
    /// chronicle, or the merged sparse span it belongs to, whose key is the span's first hour).
    public func chronicle(_ level: ChronicleLevel, containing interval: DateInterval) throws -> Chronicle? {
        try db.reader.read { d in
            try Chronicle.fetchOne(d, sql: """
                SELECT * FROM chronicle WHERE level = ? AND period_start <= ? AND period_end >= ?
                ORDER BY period_start DESC, id LIMIT 1
                """, arguments: [level.rawValue, interval.start, interval.end])
        }
    }

    /// Inserts, or replaces the row with the same `(level, period_key)` keeping its id. Returns
    /// the stored row.
    @discardableResult
    public func upsert(_ c: Chronicle, in d: Database) throws -> Chronicle {
        var row = c
        if let existing = try chronicle(c.level, key: c.periodKey, in: d) {
            row.id = existing.id
            try row.update(d)
        } else {
            row.id = nil
            try row.insert(d)
        }
        return row
    }

    /// Sets `is_dirty` on the row if it exists (a no-op otherwise).
    public func markDirty(_ level: ChronicleLevel, key: String, in d: Database) throws {
        try d.execute(sql: "UPDATE chronicle SET is_dirty = 1 WHERE level = ? AND period_key = ?",
                      arguments: [level.rawValue, key])
    }

    /// Deletes the row if it exists.
    public func delete(_ level: ChronicleLevel, key: String, in d: Database) throws {
        try d.execute(sql: "DELETE FROM chronicle WHERE level = ? AND period_key = ?", arguments: [level.rawValue, key])
    }

    /// Rows of `level` whose period overlaps `[from, to)`, oldest first.
    public func list(level: ChronicleLevel, from: Date, to: Date) throws -> [Chronicle] {
        try db.reader.read { d in
            try Chronicle.fetchAll(d, sql: """
                SELECT * FROM chronicle WHERE level = ? AND period_start < ? AND period_end > ?
                ORDER BY period_start, id
                """, arguments: [level.rawValue, to, from])
        }
    }

    /// Full-text OR search over summaries, best first; the score is `-bm25` (higher is better).
    /// `since` keeps rows whose period ends after it.
    public func search(_ terms: [String], levels: Set<ChronicleLevel>, since: Date?, limit: Int) throws
        -> [(Chronicle, Double)] {
        guard !levels.isEmpty, limit > 0, let match = FTSQuery.makeAny(terms: terms) else { return [] }
        let names = levels.map(\.rawValue).sorted()
        let marks = Array(repeating: "?", count: names.count).joined(separator: ",")
        var arguments: StatementArguments = [match]
        arguments += StatementArguments(names)
        arguments += [since, since, limit]
        return try db.reader.read { d in
            try Row.fetchAll(d, sql: """
                SELECT c.*, bm25(chronicle_fts) AS score
                FROM chronicle_fts JOIN chronicle c ON c.id = chronicle_fts.rowid
                WHERE chronicle_fts MATCH ? AND c.level IN (\(marks)) AND (? IS NULL OR c.period_end > ?)
                ORDER BY score, c.period_start DESC LIMIT ?
                """, arguments: arguments)
                .map { row in (try Chronicle(row: row), -(row["score"] as Double)) }
        }
    }
}

extension ChronicleLevel {
    /// The level a chronicle of this level is built from (months and weeks from days).
    public var childLevel: ChronicleLevel? {
        switch self {
        case .hour: nil
        case .day: .hour
        case .week, .month: .day
        case .year: .month
        }
    }
}
