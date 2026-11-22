import Capture
import Foundation
import GRDB
import Testing
@testable import Storage
@testable import Retrieval

/// Residual round #2: a database that ran the v4 of build fa8eb12 (no `snapshot_sources`, no
/// `boilerplate_stats.last_seen_at`) gets both from v4.1, keeps its data, and `DerivedPolicy`
/// works on it (tombstones written by retention are judged).
@Test func v41UpgradesADatabaseThatRanTheEarlierV4() throws {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "remora-v41-\(UUID().uuidString)", directoryHint: .isDirectory).appending(path: "remora.sqlite")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let queue = try DatabaseQueue(path: url.path)
    try Migrations.make().migrate(queue, upTo: "v4")
    let snapshotID: Int64 = try queue.write { d in
        // The fa8eb12-era v4 shape.
        try d.execute(sql: "DROP TABLE snapshot_sources")
        try d.execute(sql: "ALTER TABLE boilerplate_stats DROP COLUMN last_seen_at")
        try d.execute(sql: "INSERT INTO boilerplate_stats (surface, line_hash, line_text, docs) VALUES ('app:x', 'h', 'Sign in', 4)")
        var s = Snapshot(capturedAt: Date(timeIntervalSince1970: 1_000), app: "Slack", text: "secret", contentHash: "h",
                         source: .ax)
        try s.insert(d)
        var c = Chronicle(level: .hour, periodKey: "k", periodStart: Date(timeIntervalSince1970: 0),
                          periodEnd: Date(timeIntervalSince1970: 3_600), summary: "From Slack", snapshotIDs: [s.id!],
                          generatedAt: Date(timeIntervalSince1970: 3_600))
        try c.insert(d)
        return s.id!
    }
    try queue.close()

    let before = Date().addingTimeInterval(-60)
    let db = try AppDatabase.open(at: url)
    let (tables, statsCols, stats, chronicles): ([String], [String], [Row], Int) = try db.reader.read { d in
        (try String.fetchAll(d, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"),
         try d.columns(in: "boilerplate_stats").map(\.name),
         try Row.fetchAll(d, sql: "SELECT docs, last_seen_at FROM boilerplate_stats"),
         try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM chronicle") ?? 0)
    }
    #expect(tables.contains("snapshot_sources") && statsCols.contains("last_seen_at"))
    #expect(stats.count == 1 && (stats[0]["docs"] as Double) == 4)
    #expect((stats[0]["last_seen_at"] as Date) > before)   // stamped at upgrade, not 1970
    #expect(chronicles == 1)

    // Retention leaves a tombstone; once Slack is excluded the chronicle stays hidden.
    try db.writer.write { _ = try RetentionStore.deleteUnsummarisable([snapshotID], in: $0) }
    try ExclusionStore(db).add("app:Slack")
    let policy = SnapshotPolicy.current(db)
    let rows = try db.reader.read { d in
        try DerivedPolicy.filter(try Chronicle.fetchAll(d), ids: \.snapshotIDs, policy: policy, in: d)
    }
    #expect(rows.isEmpty)
}
