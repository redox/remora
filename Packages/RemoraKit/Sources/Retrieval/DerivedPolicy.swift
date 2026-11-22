import Capture
import Foundation
import GRDB
import Storage

/// Which derived rows (chronicles, wiki pages and facts, flags, working-memory items) may reach a
/// prompt now, judged by the snapshots they cite under the current exclusions (`SnapshotPolicy`).
/// Shared by the memory pipelines, the rewrite context and the MCP tools, so the rule has one
/// definition.
///
/// The rule (`filter`): a row is kept when it cites no judged snapshot, or when at least one cited
/// snapshot still exists and is allowed. Judged = live snapshots, plus deleted ones whose tombstone
/// (`SnapshotTombstones`: app, bundle id, domain, URL host) the policy denies.
/// - Tombstones only ever **deny**: one that passes is not judged at all, because it lacks the
///   title, file path and URL path a rule may match. So a row citing [live allowed, tombstoned
///   denied] is kept, exactly as before tombstones existed (a live allowed snapshot keeps it); a row
///   citing [live excluded, tombstoned allowed] is hidden; a row citing only tombstoned-denied ids
///   is hidden; a row whose ids are all gone with no denying tombstone stays (F-59: the text
///   outlives its evidence).
/// - Under `.denyAll` (the exclusions could not be loaded) every row is dropped, including rows
///   citing no snapshot and rows whose snapshots are all gone (fail closed).
public enum DerivedPolicy {
    /// See the type comment. Under `.denyAll`: nothing is kept.
    public static func filter<T>(_ rows: [T], ids: (T) -> [Int64], policy: CapturePolicy, in d: Database) throws -> [T] {
        if policy.deniesEverything { return [] }
        let v = try verdicts(rows.flatMap(ids), policy: policy, in: d)
        return rows.filter { row in
            let cited = Set(ids(row))
            return cited.isDisjoint(with: v.judged) || !cited.isDisjoint(with: v.liveAllowed)
        }
    }

    /// Stricter, for working memory: drops a row unless one of its cited snapshots still exists and
    /// is allowed by `policy` (all excluded or all deleted → dropped). Rows citing no snapshot are
    /// kept. Under `.denyAll`: nothing is kept.
    public static func requiringLiveEvidence<T>(_ rows: [T], ids: (T) -> [Int64], policy: CapturePolicy,
                                                in d: Database) throws -> [T] {
        if policy.deniesEverything { return [] }
        let v = try verdicts(rows.flatMap(ids), policy: policy, in: d)
        return rows.filter { row in
            let cited = ids(row)
            return cited.isEmpty || cited.contains(where: v.liveAllowed.contains)
        }
    }

    /// Of `ids`, those whose snapshot still exists and `policy` allows (the snapshot ids a tool may
    /// show). Empty under `.denyAll`.
    public static func allowedIDs(_ ids: [Int64], policy: CapturePolicy, in d: Database) throws -> Set<Int64> {
        if policy.deniesEverything { return [] }
        return try verdicts(ids, policy: policy, in: d).liveAllowed
    }

    /// Of `ids`: the judged ones (live, or tombstoned and denied) and the live allowed ones.
    private static func verdicts(_ ids: [Int64], policy: CapturePolicy, in d: Database) throws
        -> (judged: Set<Int64>, liveAllowed: Set<Int64>) {
        let wanted = Array(Set(ids))
        var judged = Set<Int64>(), live = Set<Int64>()
        for start in stride(from: 0, to: wanted.count, by: 400) {
            let chunk = Array(wanted[start..<min(start + 400, wanted.count)])
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            // Only the columns the policy looks at, never the text.
            for row in try Row.fetchAll(d, sql: """
                SELECT id, app, bundle_id, window_title, url, domain, file_path FROM snapshots WHERE id IN (\(marks))
                """, arguments: StatementArguments(chunk)) {
                let id: Int64 = row["id"]
                let s = Snapshot(id: id, capturedAt: .distantPast, app: row["app"], bundleID: row["bundle_id"],
                                 windowTitle: row["window_title"], url: row["url"], domain: row["domain"],
                                 filePath: row["file_path"], text: "", contentHash: "", source: .ax)
                judged.insert(id)
                if SnapshotPolicy.allows(s, policy: policy) { live.insert(id) }
            }
        }
        let missing = wanted.filter { !judged.contains($0) }
        for (id, t) in try SnapshotTombstones.fetch(missing, in: d) where !SnapshotPolicy.allows(snapshot(t), policy: policy) {
            judged.insert(id)   // a tombstone only adds a denial
        }
        return (judged, live)
    }

    /// A minimal snapshot carrying only a tombstone's fields: the URL is the host alone, so a URL
    /// rule sees `https://<host>` and a domain rule the real host.
    private static func snapshot(_ t: SnapshotTombstone) -> Snapshot {
        Snapshot(id: t.id, capturedAt: .distantPast, app: t.app, bundleID: t.bundleID,
                 url: t.urlHost.map { "https://\($0)" }, domain: t.domain, text: "", contentHash: "", source: .ax)
    }
}
