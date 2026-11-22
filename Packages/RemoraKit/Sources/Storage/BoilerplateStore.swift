import Foundation
import GRDB

/// Candidate interface lines seen in ONE captured document of a surface: hash -> normalised text.
/// Lives in Storage (not Capture) because `SnapshotStore` records it in the insert transaction.
public struct BoilerplateSample: Sendable, Equatable {
    public static let maxLines = 300
    public var surface: String
    public var lines: [String: String]
    public init(surface: String, lines: [String: String]) {
        self.surface = surface
        self.lines = lines
    }
}

/// Per-surface interface clutter statistics and the lines learned from them.
/// Line texts are captured text: never log them.
public struct BoilerplateStore: Sendable {
    public static let minDocs = 20.0
    public static let learnShare = 0.80
    public static let forgetShare = 0.60
    public static let halveAbove = 200.0

    private let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    /// The learned line hashes of one surface.
    public func learned(surface: String) throws -> Set<String> {
        try db.reader.read { d in
            Set(try String.fetchAll(d, sql: "SELECT line_hash FROM boilerplate WHERE surface = ?",
                                    arguments: [surface]))
        }
    }

    /// Counts one document for the surface and each of its lines, seen `at` (`last_seen_at`).
    /// Runs inside the caller's write transaction (GRDB writes are not reentrant).
    public static func record(_ s: BoilerplateSample, at: Date = Date(), in d: Database) throws {
        try d.execute(sql: """
            INSERT INTO boilerplate_surfaces (surface, docs, fitted_at) VALUES (?, 1, NULL)
            ON CONFLICT(surface) DO UPDATE SET docs = docs + 1
            """, arguments: [s.surface])
        for (hash, text) in s.lines.prefix(BoilerplateSample.maxLines) {
            try d.execute(sql: """
                INSERT INTO boilerplate_stats (surface, line_hash, line_text, docs, last_seen_at) VALUES (?, ?, ?, 1, ?)
                ON CONFLICT(surface, line_hash) DO UPDATE SET docs = docs + 1, last_seen_at = excluded.last_seen_at
                """, arguments: [s.surface, hash, text, at])
        }
    }

    /// Deletes stats rows (captured line text) last seen before `cutoff` (the retention window).
    /// Returns how many.
    @discardableResult
    public static func pruneStats(lastSeenBefore cutoff: Date, in d: Database) throws -> Int {
        try d.execute(sql: "DELETE FROM boilerplate_stats WHERE last_seen_at < ?", arguments: [cutoff])
        return d.changesCount
    }

    /// Every surface with stats, learned lines or a document count.
    public static func surfaces(in d: Database) throws -> [String] {
        try String.fetchAll(d, sql: """
            SELECT surface FROM boilerplate_stats UNION SELECT surface FROM boilerplate
            UNION SELECT surface FROM boilerplate_surfaces ORDER BY 1
            """)
    }

    /// Forgets `surfaces` entirely: stats, learned lines and document counts. Returns how many
    /// stats and learned rows were deleted.
    @discardableResult
    public static func drop(surfaces: [String], in d: Database) throws -> Int {
        var removed = 0
        for surface in surfaces {
            for table in ["boilerplate_stats", "boilerplate"] {
                try d.execute(sql: "DELETE FROM \(table) WHERE surface = ?", arguments: [surface])
                removed += d.changesCount
            }
            try d.execute(sql: "DELETE FROM boilerplate_surfaces WHERE surface = ?", arguments: [surface])
        }
        return removed
    }

    public func isFitted(surface: String) throws -> Bool {
        try db.reader.read { d in
            try Bool.fetchOne(d, sql: "SELECT fitted_at IS NOT NULL FROM boilerplate_surfaces WHERE surface = ?",
                              arguments: [surface]) ?? false
        }
    }

    /// Surfaces with enough documents that were never fitted.
    public func surfacesNeedingFirstFit() throws -> [String] {
        try db.reader.read { d in
            try String.fetchAll(d, sql: """
                SELECT surface FROM boilerplate_surfaces WHERE docs >= ? AND fitted_at IS NULL
                ORDER BY surface
                """, arguments: [Self.minDocs])
        }
    }

    /// Halves counts of a surface above 200 docs, prunes stats rows below one document (they
    /// hold captured text and must not outlive their evidence), then learns lines at share
    /// >= 0.80 (surface docs >= 20) and forgets learned lines below 0.60. `nil` = all surfaces.
    @discardableResult
    public func refresh(surface: String?, at: Date) throws -> (learned: Int, forgotten: Int) {
        try db.writer.write { d in try Self.refresh(surface: surface, at: at, in: d) }
    }

    /// Inside an existing write (compaction runs it in `DataGeneration.write`).
    @discardableResult
    public static func refresh(surface: String?, at: Date, in d: Database) throws -> (learned: Int, forgotten: Int) {
        let surfaces: [String] = try surface.map { [$0] }
            ?? String.fetchAll(d, sql: "SELECT surface FROM boilerplate_surfaces")
        var learned = 0, forgotten = 0
        for s in surfaces {
            guard var docs = try Double.fetchOne(
                d, sql: "SELECT docs FROM boilerplate_surfaces WHERE surface = ?", arguments: [s])
            else { continue }
            if docs > Self.halveAbove {
                docs /= 2
                try d.execute(sql: "UPDATE boilerplate_surfaces SET docs = ? WHERE surface = ?",
                              arguments: [docs, s])
                try d.execute(sql: "UPDATE boilerplate_stats SET docs = docs / 2 WHERE surface = ?",
                              arguments: [s])
            }
            try d.execute(sql: "DELETE FROM boilerplate_stats WHERE surface = ? AND docs < 1", arguments: [s])

            if docs >= Self.minDocs {
                let before = try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM boilerplate WHERE surface = ?",
                                              arguments: [s]) ?? 0
                try d.execute(sql: """
                    INSERT INTO boilerplate (surface, line_hash, line_text, learned_at)
                    SELECT surface, line_hash, line_text, ? FROM boilerplate_stats
                    WHERE surface = ? AND docs >= ?
                    ON CONFLICT(surface, line_hash) DO NOTHING
                    """, arguments: [at, s, Self.learnShare * docs])
                let after = try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM boilerplate WHERE surface = ?",
                                             arguments: [s]) ?? 0
                learned += after - before
            }
            try d.execute(sql: """
                DELETE FROM boilerplate WHERE surface = ? AND NOT EXISTS (
                    SELECT 1 FROM boilerplate_stats t
                    WHERE t.surface = boilerplate.surface AND t.line_hash = boilerplate.line_hash
                      AND t.docs >= ?)
                """, arguments: [s, Self.forgetShare * docs])
            forgotten += d.changesCount
            if docs >= Self.minDocs {
                try d.execute(sql: "UPDATE boilerplate_surfaces SET fitted_at = ? WHERE surface = ?",
                              arguments: [at, s])
            }
        }
        return (learned, forgotten)
    }
}
