import Foundation
import GRDB
import Testing
@testable import Storage

@Test func v3MigratesExistingV2Data() throws {
    let url = tempDir().appending(path: "remora.sqlite")
    let queue = try DatabaseQueue(path: url.path)
    try Migrations.make().migrate(queue, upTo: "v2")
    try queue.write { d in
        try d.execute(sql: """
            INSERT INTO snapshots (captured_at, app, window_title, text, content_hash, source)
            VALUES (?, 'Notes', 'T', 'hello world', 'h1', 'ax')
            """, arguments: [Date(timeIntervalSince1970: 1_000)])
    }
    try queue.close()

    let db = try AppDatabase.open(at: url)
    let (tables, indexes): ([String], [String]) = try db.reader.read { d in
        (try String.fetchAll(d, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"),
         try String.fetchAll(d, sql: "SELECT name FROM sqlite_master WHERE type = 'index'"))
    }
    #expect(try SnapshotStore(db).recent(limit: 5).count == 1)
    for t in ["llm_calls", "inline_outputs", "style_notes"] { #expect(tables.contains(t)) }
    #expect(indexes.contains("llm_calls_on_job_type_started_at"))
    #expect(indexes.contains("llm_calls_on_started_at"))
    #expect(indexes.contains("inline_outputs_on_created_at"))
}
