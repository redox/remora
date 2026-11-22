import Foundation
import GRDB

/// What a provenance cascade changed, by table: rows deleted, and rows that only lost ids (and
/// were marked dirty where the table has a dirty flag). `deleted["embeddings"]` counts vectors of
/// deleted owners; `dirtied["chronicle"]` includes the ancestors marked dirty.
public struct ProvenanceReport: Sendable, Equatable {
    public var deleted: [String: Int]
    public var dirtied: [String: Int]

    public init(deleted: [String: Int] = [:], dirtied: [String: Int] = [:]) {
        self.deleted = deleted; self.dirtied = dirtied
    }
}

/// Removes forgotten snapshots from everything derived from them. Only the user-initiated
/// `SnapshotStore.delete(ids:)` runs it: retention never cascades (F-61), because chronicles are
/// meant to outlive the raw captures they summarise.
///
/// For `chronicle`, `wiki_facts`, `wiki_pages`, `salient_flags` and `working_memory`, rows citing a
/// deleted id (found with `json_each(snapshot_ids)`) are handled so:
/// - every cited id deleted: the row is deleted. A row with an EMPTY `snapshot_ids` never matches,
///   so week, month and year chronicles (which store `[]` and carry provenance through
///   `child_ids`) are never taken for "all deleted";
/// - otherwise the deleted ids are removed and the row is marked dirty (`chronicle.is_dirty`; a
///   fact's page `wiki_pages.is_dirty`). Flags and working memory have no dirty flag and only lose
///   ids (flags also lose them from `close_snapshot_ids`).
///
/// Facts are handled before pages: a deleted fact marks its page dirty, and a page whose own ids
/// are all gone is deleted only when no fact is left on it (its facts would go with it, through
/// the foreign key); otherwise it takes the surviving facts' ids as its provenance and is marked
/// dirty. `superseded_by` of a fact pointing at a deleted one becomes NULL (`ON DELETE SET NULL`).
///
/// Every chronicle the cascade dirties or deletes touches all its ancestors, transitively (hour
/// → day → week and month → year), here and now, without waiting for a re-roll: an ancestor row
/// containing the chronicle's start is marked dirty; with no row, a finished (`done`/`skipped`)
/// rollup job of that level overlapping it is requeued — the rule `ChronicleParents.touch` applies
/// one level at a time. A deleted day, week, month or year also requeues its own finished rollup,
/// so children that survive (activity-only hours) get a row again. Vectors of deleted owners are
/// removed. Every page left dirty with fewer than `WikiStore.minRewriteMentions` mentions is never
/// rewritten, so its summary and body are blanked (and its vector dropped) here.
public enum Provenance {
    static let chunk = 500

    @discardableResult
    public static func cascade(deletedSnapshotIDs: Set<Int64>, now: Date = Date(), in d: Database) throws
        -> ProvenanceReport {
        guard !deletedSnapshotIDs.isEmpty else { return ProvenanceReport() }
        let gone = deletedSnapshotIDs
        var report = ProvenanceReport()
        // Forgotten ids are gone for good: no tombstone keeps judging them.
        try SnapshotTombstones.remove(Array(gone), in: d)
        func bump(_ key: WritableKeyPath<ProvenanceReport, [String: Int]>, _ table: String, by n: Int = 1) {
            guard n > 0 else { return }
            report[keyPath: key][table, default: 0] += n
        }

        // Chronicles.
        var dirtyChronicles = Set<Int64>()
        var touched: [(ChronicleLevel, Date)] = []
        for row in try citing("chronicle", column: "snapshot_ids", ids: gone, extra: "level, period_key, period_start", in: d) {
            guard let level = ChronicleLevel(rawValue: row.extra["level"] ?? "") else { continue }
            let start: Date = row.extra["period_start"]
            let remaining = row.ids.filter { !gone.contains($0) }
            if remaining.isEmpty {
                try d.execute(sql: "DELETE FROM chronicle WHERE id = ?", arguments: [row.id])
                bump(\.deleted, "chronicle")
                // A deleted rollup is rebuilt from the children that survive (activity-only hours).
                if level != .hour {
                    try requeueFinished(level.jobKind, periodKey: row.extra["period_key"], now: now, in: d)
                }
            } else {
                try d.execute(sql: "UPDATE chronicle SET snapshot_ids = ?, is_dirty = 1 WHERE id = ?",
                              arguments: [try json(remaining), row.id])
                dirtyChronicles.insert(row.id)
            }
            touched.append((level, start))
        }
        for (level, start) in touched {
            dirtyChronicles.formUnion(try touchAncestors(of: level, start: start, now: now, in: d))
        }
        bump(\.dirtied, "chronicle", by: dirtyChronicles.count)

        // Facts, then pages.
        var dirtyPages = Set<String>()
        for row in try citing("wiki_facts", column: "snapshot_ids", ids: gone, extra: "slug", in: d) {
            let slug: String = row.extra["slug"]
            let remaining = row.ids.filter { !gone.contains($0) }
            if remaining.isEmpty {
                try d.execute(sql: "DELETE FROM wiki_facts WHERE id = ?", arguments: [row.id])
                bump(\.deleted, "wiki_facts")
            } else {
                try d.execute(sql: "UPDATE wiki_facts SET snapshot_ids = ? WHERE id = ?",
                              arguments: [try json(remaining), row.id])
                bump(\.dirtied, "wiki_facts")
            }
            dirtyPages.insert(slug)
        }
        for row in try citing("wiki_pages", column: "snapshot_ids", ids: gone, extra: "slug", in: d) {
            let slug: String = row.extra["slug"]
            var remaining = row.ids.filter { !gone.contains($0) }
            if remaining.isEmpty {
                let factIDs = try String.fetchAll(d, sql: "SELECT snapshot_ids FROM wiki_facts WHERE slug = ?",
                                                  arguments: [slug])
                if factIDs.isEmpty {
                    try d.execute(sql: "DELETE FROM wiki_pages WHERE id = ?", arguments: [row.id])
                    bump(\.deleted, "wiki_pages")
                    dirtyPages.remove(slug)
                    continue
                }
                remaining = Array(Set(factIDs.compactMap(decode).flatMap { $0 })).sorted()
            }
            try d.execute(sql: "UPDATE wiki_pages SET snapshot_ids = ? WHERE id = ?",
                          arguments: [try json(remaining), row.id])
            dirtyPages.insert(slug)
        }
        for slug in dirtyPages.sorted() {
            try d.execute(sql: "UPDATE wiki_pages SET is_dirty = 1 WHERE slug = ?", arguments: [slug])
            if d.changesCount > 0 { bump(\.dirtied, "wiki_pages") }
            // A page below the rewrite threshold is never rewritten, so its write-up (which may
            // quote what was forgotten) is blanked now, and its vector goes until it is re-embedded.
            try d.execute(sql: """
                UPDATE wiki_pages SET summary = '', body = '', updated_at = ?
                WHERE slug = ? AND mention_count < ? AND (summary <> '' OR body <> '')
                """, arguments: [now, slug, WikiStore.minRewriteMentions])
            if d.changesCount > 0 {
                try d.execute(sql: """
                    DELETE FROM embeddings WHERE owner_table = 'wiki_pages'
                      AND owner_id = (SELECT id FROM wiki_pages WHERE slug = ?)
                    """, arguments: [slug])
                bump(\.dirtied, "wiki_pages_blanked")
            }
        }

        // Flags and working memory: no dirty flag, they only lose ids.
        for table in ["salient_flags", "working_memory"] {
            for row in try citing(table, column: "snapshot_ids", ids: gone, in: d) {
                let remaining = row.ids.filter { !gone.contains($0) }
                if remaining.isEmpty {
                    try d.execute(sql: "DELETE FROM \(table) WHERE id = ?", arguments: [row.id])
                    bump(\.deleted, table)
                } else {
                    try d.execute(sql: "UPDATE \(table) SET snapshot_ids = ? WHERE id = ?",
                                  arguments: [try json(remaining), row.id])
                    bump(\.dirtied, table)
                }
            }
        }
        for row in try citing("salient_flags", column: "close_snapshot_ids", ids: gone, in: d) {
            try d.execute(sql: "UPDATE salient_flags SET close_snapshot_ids = ? WHERE id = ?",
                          arguments: [try json(row.ids.filter { !gone.contains($0) }), row.id])
        }

        bump(\.deleted, "embeddings", by: try EmbeddingStore.deleteOrphans(in: d))
        return report
    }

    /// Every level above `level`, nearest first (hour → day, week, month, year).
    static func ancestors(of level: ChronicleLevel) -> [ChronicleLevel] {
        var out: [ChronicleLevel] = []
        var queue = level.parents
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if !out.contains(next) { out.append(next); queue += next.parents }
        }
        return out
    }

    /// Marks every ancestor row containing `start` dirty, or requeues a finished rollup of a level
    /// that has no row. Returns the ids of the rows marked dirty.
    static func touchAncestors(of level: ChronicleLevel, start: Date, now: Date, in d: Database) throws -> Set<Int64> {
        var dirtied = Set<Int64>()
        for ancestor in ancestors(of: level) {
            let ids = try Int64.fetchAll(d, sql: """
                SELECT id FROM chronicle WHERE level = ? AND period_start <= ? AND period_end > ?
                """, arguments: [ancestor.rawValue, start, start])
            if ids.isEmpty {
                try d.execute(sql: """
                    UPDATE jobs SET status = 'pending', attempts = 0, next_run_at = ?, last_error = NULL, updated_at = ?
                    WHERE kind = ? AND period_start <= ? AND period_end > ? AND status IN ('done', 'skipped')
                    """, arguments: [now, now, ancestor.jobKind.rawValue, start, start])
                continue
            }
            for id in ids {
                try d.execute(sql: "UPDATE chronicle SET is_dirty = 1 WHERE id = ?", arguments: [id])
                dirtied.insert(id)
            }
        }
        return dirtied
    }

    /// A `done` or `skipped` job back to pending (the rule `ChronicleParents.touch` uses).
    private static func requeueFinished(_ kind: JobKind, periodKey: String, now: Date, in d: Database) throws {
        try d.execute(sql: """
            UPDATE jobs SET status = 'pending', attempts = 0, next_run_at = ?, last_error = NULL, updated_at = ?
            WHERE kind = ? AND period_key = ? AND status IN ('done', 'skipped')
            """, arguments: [now, now, kind.rawValue, periodKey])
    }

    struct Citing {
        var id: Int64
        var ids: [Int64]
        var extra: Row
    }

    /// Rows of `table` whose JSON array `column` holds any of `ids` (each row once), with the
    /// decoded array and the `extra` columns.
    static func citing(_ table: String, column: String, ids: Set<Int64>, extra: String? = nil,
                       in d: Database) throws -> [Citing] {
        let wanted = ids.sorted()
        var seen = Set<Int64>()
        var out: [Citing] = []
        let columns = ["t.id", "t.\(column) AS ids"] + (extra.map { [$0.split(separator: ",").map {
            "t." + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")] } ?? [])
        for start in stride(from: 0, to: wanted.count, by: chunk) {
            let part = Array(wanted[start..<min(start + chunk, wanted.count)])
            let marks = Array(repeating: "?", count: part.count).joined(separator: ",")
            let rows = try Row.fetchAll(d, sql: """
                SELECT \(columns.joined(separator: ", ")) FROM \(table) t
                WHERE EXISTS (SELECT 1 FROM json_each(t.\(column)) j WHERE j.value IN (\(marks)))
                ORDER BY t.id
                """, arguments: StatementArguments(part))
            for row in rows {
                let id: Int64 = row["id"]
                // An array that does not decode is left alone rather than taken for "all deleted".
                guard seen.insert(id).inserted, let decoded = decode(row["ids"]) else { continue }
                out.append(Citing(id: id, ids: decoded, extra: row))
            }
        }
        return out
    }

    static func decode(_ raw: String?) -> [Int64]? {
        guard let raw else { return nil }
        return try? JSONDecoder().decode([Int64].self, from: Data(raw.utf8))
    }

    static func json(_ ids: [Int64]) throws -> String {
        String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)
    }
}
