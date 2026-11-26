import GRDB
import Storage
import Testing

@Test func localRecordingsHaveTheirOwnSearchIndexAndAreScrubbedByDeleteAll() throws {
    let db = try AppDatabase.inMemory()
    try db.reader.read { d throws in
        #expect(try d.columns(in: "chat_turns").contains { $0.name == "recording_ids" })
        try #require(try d.tableExists("local_meetings"))
        #expect(try d.tableExists("local_meetings_fts"))
    }
    try db.writer.write { d throws in
        try d.execute(sql: """
            INSERT INTO local_meetings(id, started_at, client, title, transcript, interrupted, source_app, source_bundle)
            VALUES(randomblob(16), CURRENT_TIMESTAMP, 'Zoom', 'Planning', 'telescope', 0, 'Zoom', 'us.zoom.xos')
            """)
    }
    for access in RecordingSearchAccess.allCases { try access.set(true, in: db) }
    try DataReset.deleteAllCapturedData(in: db)
    for access in RecordingSearchAccess.allCases { #expect(try !access.enabled(in: db)) }
    try db.reader.read { d throws in
        #expect(try Int.fetchOne(d, sql: "SELECT count(*) FROM local_meetings") == 0)
        #expect(try Int.fetchOne(d, sql: "SELECT count(*) FROM local_meetings_fts WHERE local_meetings_fts MATCH 'telescope'") == 0)
    }
}
