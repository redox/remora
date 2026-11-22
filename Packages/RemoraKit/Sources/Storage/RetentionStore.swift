import Foundation
import GRDB

/// Which raw captures the retention window may delete (plan 4 Review Focus 5).
///
/// A snapshot is deletable when it is older than the cutoff **and** summarised **and** cited by
/// no evidence that still matters:
/// - a clean `hour` chronicle covers it: one whose `[period_start, period_end)` contains its
///   `captured_at`, and (for a rolling row, live from `first_captured_at`) one containing its
///   `first_captured_at` too, so every hour it was live in has been summarised; "clean" = not
///   dirty and with its entities, facts and flags extracted (`metadata.entities_done`);
/// - no `wiki_facts.snapshot_ids` cites it, valid or not;
/// - no `salient_flags.snapshot_ids` of an `open` flag cites it.
///
/// Retention never cascades (F-61): chronicle provenance arrays keep the deleted ids (they record
/// what was summarised; `get_snapshots` returns nothing for them). With memory off nothing gets
/// summarised, so nothing is deleted (F-36): `awaitingSummary` counts what is held back for that.
/// One exception (controller ruling relaxing F-36): an uncovered, uncited snapshot whose app or
/// site the current exclusions no longer allow can never be summarised, so compaction removes it
/// through `uncoveredCandidates` + `deleteUnsummarisable`.
public struct RetentionStore: Sendable {
    public static let batchSize = 500

    private let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    /// Deletable ids captured before `cutoff`, oldest first, at most `limit`.
    public func deletable(olderThan cutoff: Date, limit: Int) throws -> [Int64] {
        guard limit > 0 else { return [] }
        return try db.reader.read { d in
            try Int64.fetchAll(d, sql: """
                \(Self.citedCTE)
                SELECT s.id FROM snapshots s
                WHERE s.captured_at < ? AND \(Self.evidencePredicate)
                ORDER BY s.captured_at, s.id LIMIT ?
                """, arguments: [cutoff, limit])
        }
    }

    /// Deletes those of `ids` that are still deletable apart from their age (the evidence check is
    /// repeated inside this transaction, so a fact or open flag that cited one meanwhile keeps it).
    /// Snapshots only: no cascade. Returns how many rows were deleted.
    @discardableResult
    public func delete(_ ids: [Int64]) throws -> Int {
        try db.writer.write { d in try Self.delete(ids, in: d) }
    }

    /// Inside an existing write (e.g. `DataGeneration.write`). Each deleted snapshot leaves its
    /// tombstone (`SnapshotTombstones`) in the same transaction.
    @discardableResult
    public static func delete(_ ids: [Int64], in d: Database) throws -> Int {
        var deleted = 0
        for start in stride(from: 0, to: ids.count, by: batchSize) {
            let part = Array(ids[start..<min(start + batchSize, ids.count)])
            let marks = Array(repeating: "?", count: part.count).joined(separator: ",")
            let doomed = try Int64.fetchAll(d, sql: """
                \(citedCTE)
                SELECT s.id FROM snapshots s WHERE s.id IN (\(marks)) AND \(evidencePredicate)
                """, arguments: StatementArguments(part))
            deleted += try deleteWithTombstones(doomed, in: d)
        }
        return deleted
    }

    /// Records the tombstones of `ids`, then deletes their snapshots (ids already checked).
    private static func deleteWithTombstones(_ ids: [Int64], in d: Database) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        try SnapshotTombstones.record(ids, in: d)
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        try d.execute(sql: "DELETE FROM snapshots WHERE id IN (\(marks))", arguments: StatementArguments(ids))
        return d.changesCount
    }

    /// Snapshots captured before `cutoff` that no hour chronicle covers yet, which compaction
    /// keeps until memory summarises them (Settings shows this when memory is off, F-36). Rows
    /// that `deleteUnsummarisable` would remove (uncited, and `isAllowed` false under the current
    /// exclusions) are not counted. `isAllowed` runs inside `db.reader.read`: build whatever it
    /// needs from the database (e.g. the `CapturePolicy` from `ExclusionStore`) before calling,
    /// because GRDB reads are not reentrant.
    public func awaitingSummary(olderThan cutoff: Date, isAllowed: (Snapshot) -> Bool) throws -> Int {
        try db.reader.read { d in
            var count = 0
            var after: Int64 = 0
            while true {
                let page = try Self.uncovered(olderThan: cutoff, afterID: after, limit: Self.batchSize,
                                              uncitedOnly: false, in: d)
                guard let last = page.last?.snapshot.id else { return count }
                count += page.filter { $0.cited || isAllowed($0.snapshot) }.count
                after = last
            }
        }
    }

    /// Snapshots captured before `cutoff` that no clean hour covers and nothing cites (any fact,
    /// valid or not; any open flag), by id after `afterID`, at most `limit`. Their text is not
    /// loaded (`text` is empty): the caller only judges where they came from. Compaction deletes
    /// those the current exclusions no longer allow (`deleteUnsummarisable`): no hour job will
    /// ever summarise them.
    public func uncoveredCandidates(olderThan cutoff: Date, afterID: Int64, limit: Int) throws -> [Snapshot] {
        guard limit > 0 else { return [] }
        return try db.reader.read { d in
            try Self.uncovered(olderThan: cutoff, afterID: afterID, limit: limit, uncitedOnly: true, in: d).map(\.snapshot)
        }
    }

    /// Deletes those of `ids` that nothing cites, re-checked inside this transaction (call it in
    /// `DataGeneration.write`), each leaving its tombstone. Snapshots only: no cascade (F-61).
    /// Returns how many were deleted.
    @discardableResult
    public static func deleteUnsummarisable(_ ids: [Int64], in d: Database) throws -> Int {
        var deleted = 0
        for start in stride(from: 0, to: ids.count, by: batchSize) {
            let part = Array(ids[start..<min(start + batchSize, ids.count)])
            let marks = Array(repeating: "?", count: part.count).joined(separator: ",")
            let doomed = try Int64.fetchAll(d, sql: """
                \(citedCTE)
                SELECT id FROM snapshots WHERE id IN (\(marks)) AND id NOT IN (SELECT id FROM cited)
                """, arguments: StatementArguments(part))
            deleted += try deleteWithTombstones(doomed, in: d)
        }
        return deleted
    }

    /// Uncovered rows older than `cutoff` after `afterID` (by id), without their text, each with
    /// whether something cites it.
    private static func uncovered(olderThan cutoff: Date, afterID: Int64, limit: Int, uncitedOnly: Bool,
                                  in d: Database) throws -> [(snapshot: Snapshot, cited: Bool)] {
        try Row.fetchAll(d, sql: """
            \(citedCTE)
            SELECT s.id, s.captured_at, s.app, s.bundle_id, s.window_title, s.url, s.domain, s.file_path,
                   '' AS text, s.content_hash, s.source, s.first_captured_at,
                   s.id IN (SELECT id FROM cited) AS is_cited
            FROM snapshots s
            WHERE s.captured_at < ? AND s.id > ? AND NOT (\(covered))
              \(uncitedOnly ? "AND s.id NOT IN (SELECT id FROM cited)" : "")
            ORDER BY s.id LIMIT ?
            """, arguments: [cutoff, afterID, limit]).map { (try Snapshot(row: $0), $0["is_cited"] as Bool) }
    }

    /// The ids any fact (valid or not) or open flag cites.
    static let citedCTE = """
        WITH cited(id) AS (
            SELECT j.value FROM wiki_facts f, json_each(f.snapshot_ids) j
            UNION
            SELECT j.value FROM salient_flags g, json_each(g.snapshot_ids) j WHERE g.status = 'open')
        """

    /// The hour whose start is the latest at or before `t` must end after it (hour spans do not
    /// overlap, so this is containment, read through `chronicle_on_level_period_start` without a
    /// scan) and be fully summarised: not dirty, and its entities, facts and flags extracted
    /// (`metadata.entities_done`). The flags are read on that containing row, so a dirty hour never
    /// falls back to an earlier clean one.
    private static func hourContains(_ t: String) -> String {
        """
        COALESCE((SELECT c.period_end > \(t) AND c.is_dirty = 0
                         AND COALESCE(json_extract(c.metadata, '$.entities_done'), 0) = 1
                  FROM chronicle c
                  WHERE c.level = 'hour' AND c.period_start <= \(t)
                  ORDER BY c.period_start DESC LIMIT 1), 0)
        """
    }

    static let covered = "\(hourContains("s.captured_at")) AND \(hourContains("COALESCE(s.first_captured_at, s.captured_at)"))"

    static let evidencePredicate = "\(covered) AND s.id NOT IN (SELECT id FROM cited)"
}
