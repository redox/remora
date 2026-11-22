import Foundation
import GRDB
import Testing
@testable import Storage

private func plan(_ d: Database, _ sql: String, _ args: StatementArguments) throws -> [String] {
    try Row.fetchAll(d, sql: "EXPLAIN QUERY PLAN " + sql, arguments: args).map { $0["detail"] as String }
}

/// The per-tick queries must use an index: no full table SCAN, no temp B-tree for ORDER BY.
@Test func perTickQueriesUseIndexes() throws {
    let db = try AppDatabase.inMemory()
    try db.reader.read { d in
        let hash = try plan(d, SnapshotStore.latestHashSQL, ["Notes", "T", "ax"])
        #expect(!hash.contains { $0.hasPrefix("SCAN") || $0.contains("TEMP B-TREE") }, "\(hash)")
        #expect(hash.contains { $0.contains("COVERING INDEX") }, "\(hash)")
        let open = try plan(d, ActivityStore.openEventSQL, [])
        #expect(!open.contains { $0.contains("TEMP B-TREE") }, "\(open)")
        let since = try plan(d, ActivityStore.eventsSinceSQL, [Date()])
        #expect(!since.contains { $0 == "SCAN activity_events" }, "\(since)")
    }
}

/// v2 must apply cleanly on a database that already holds v1 data (the user's real DB).
@Test func v2MigratesExistingV1Data() throws {
    let url = tempDir().appending(path: "remora.sqlite")
    let queue = try DatabaseQueue(path: url.path)
    try Migrations.make().migrate(queue, upTo: "v1")
    try queue.write { d in
        try d.execute(sql: """
            INSERT INTO snapshots (captured_at, app, window_title, text, content_hash, source)
            VALUES (?, 'Notes', 'T', 'hello world', 'h1', 'ax')
            """, arguments: [Date(timeIntervalSince1970: 1_000)])
        try d.execute(sql: """
            INSERT INTO activity_events (app, started_at, ended_at) VALUES ('Notes', ?, ?)
            """, arguments: [Date(timeIntervalSince1970: 1_000), Date(timeIntervalSince1970: 1_005)])
    }
    try queue.close()

    let db = try AppDatabase.open(at: url)
    let (applied, indexes, rows): ([String], [String], Int) = try db.reader.read { d in
        (try DatabaseMigrator.appliedIdentifiers(Migrations.make(), d),
         try String.fetchAll(d, sql: "SELECT name FROM sqlite_master WHERE type = 'index'"),
         try Int.fetchOne(d, sql: "SELECT count(*) FROM snapshots_fts WHERE snapshots_fts MATCH 'hello'") ?? 0)
    }
    #expect(applied.contains("v2"))
    #expect(indexes.contains("snapshots_on_app_title_source_time_hash"))
    #expect(indexes.contains("activity_events_on_ended_at"))
    #expect(rows == 1)
    #expect(try SnapshotStore(db).latestHash(app: "Notes", windowTitle: "T", source: .ax) == "h1")
    // Existing rows get first_captured_at = captured_at.
    let migrated = try #require(try SnapshotStore(db).recent(limit: 1).first)
    let row = try #require(try SnapshotStore(db).snapshots(ids: [migrated.id]).first)
    #expect(row.firstCapturedAt == Date(timeIntervalSince1970: 1_000))
}

private extension DatabaseMigrator {
    static func appliedIdentifiers(_ m: DatabaseMigrator, _ d: Database) throws -> [String] {
        Array(try m.appliedIdentifiers(d))
    }
}
