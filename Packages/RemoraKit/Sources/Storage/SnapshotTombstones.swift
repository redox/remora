import Foundation
import GRDB

/// Where a snapshot deleted by retention came from: its app, bundle id, domain and URL host, and
/// no text (`snapshot_sources`). Derived rows keep citing deleted ids (retention never cascades,
/// F-61), so `DerivedPolicy` judges those ids from their tombstone under the exclusions as they
/// stand now: an app excluded after its snapshots aged out still hides what was learned from it.
///
/// - Retention (`RetentionStore.delete`, `deleteUnsummarisable`) records them in the deleting
///   transaction; forgetting (`Provenance.cascade`) removes the forgotten ids' tombstones;
///   delete-all empties the table; compaction prunes those no derived row cites (`pruneUncited`).
public struct SnapshotTombstone: Sendable, Equatable {
    public var id: Int64
    public var app: String
    public var bundleID: String?
    public var domain: String?
    public var urlHost: String?

    public init(id: Int64, app: String, bundleID: String?, domain: String?, urlHost: String?) {
        self.id = id; self.app = app; self.bundleID = bundleID; self.domain = domain; self.urlHost = urlHost
    }
}

public enum SnapshotTombstones {
    static let chunk = 400

    /// Records the tombstones of `ids` from their snapshot rows (call before deleting them, in the
    /// same transaction). Ids without a row are ignored.
    public static func record(_ ids: [Int64], in d: Database) throws {
        for start in stride(from: 0, to: ids.count, by: chunk) {
            let part = Array(ids[start..<min(start + chunk, ids.count)])
            let marks = Array(repeating: "?", count: part.count).joined(separator: ",")
            for row in try Row.fetchAll(d, sql: "SELECT id, app, bundle_id, url, domain FROM snapshots WHERE id IN (\(marks))",
                                        arguments: StatementArguments(part)) {
                let url: String? = row["url"]
                let host = url.flatMap { URL(string: $0)?.host() }.flatMap { $0.isEmpty ? nil : $0.lowercased() }
                try d.execute(sql: """
                    INSERT OR REPLACE INTO snapshot_sources (id, app, bundle_id, domain, url_host) VALUES (?, ?, ?, ?, ?)
                    """, arguments: [row["id"] as Int64, row["app"] as String, row["bundle_id"] as String?,
                                     row["domain"] as String?, host])
            }
        }
    }

    /// The tombstones of `ids`, by id.
    public static func fetch(_ ids: [Int64], in d: Database) throws -> [Int64: SnapshotTombstone] {
        var out: [Int64: SnapshotTombstone] = [:]
        for start in stride(from: 0, to: ids.count, by: chunk) {
            let part = Array(ids[start..<min(start + chunk, ids.count)])
            let marks = Array(repeating: "?", count: part.count).joined(separator: ",")
            for row in try Row.fetchAll(d, sql: """
                SELECT id, app, bundle_id, domain, url_host FROM snapshot_sources WHERE id IN (\(marks))
                """, arguments: StatementArguments(part)) {
                let id: Int64 = row["id"]
                out[id] = SnapshotTombstone(id: id, app: row["app"] ?? "", bundleID: row["bundle_id"],
                                            domain: row["domain"], urlHost: row["url_host"])
            }
        }
        return out
    }

    /// Removes the tombstones of `ids` (forgotten snapshots). Returns how many were removed.
    @discardableResult
    public static func remove(_ ids: [Int64], in d: Database) throws -> Int {
        var removed = 0
        for start in stride(from: 0, to: ids.count, by: chunk) {
            let part = Array(ids[start..<min(start + chunk, ids.count)])
            let marks = Array(repeating: "?", count: part.count).joined(separator: ",")
            try d.execute(sql: "DELETE FROM snapshot_sources WHERE id IN (\(marks))", arguments: StatementArguments(part))
            removed += d.changesCount
        }
        return removed
    }

    /// Removes the tombstones no derived row cites any more (chronicles, wiki pages and facts,
    /// flags with their closing ids, working memory). Returns how many were removed.
    @discardableResult
    public static func pruneUncited(in d: Database) throws -> Int {
        try d.execute(sql: """
            DELETE FROM snapshot_sources WHERE id NOT IN (
                SELECT j.value FROM chronicle c, json_each(c.snapshot_ids) j
                UNION SELECT j.value FROM wiki_pages p, json_each(p.snapshot_ids) j
                UNION SELECT j.value FROM wiki_facts f, json_each(f.snapshot_ids) j
                UNION SELECT j.value FROM salient_flags g, json_each(g.snapshot_ids) j
                UNION SELECT j.value FROM salient_flags g, json_each(g.close_snapshot_ids) j
                UNION SELECT j.value FROM working_memory w, json_each(w.snapshot_ids) j)
            """)
        return d.changesCount
    }
}
