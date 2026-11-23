import Foundation
import GRDB
import Testing
@testable import Storage

@Test func v4MigratesV3Database() throws {
    let url = tempDir().appending(path: "remora.sqlite")
    let queue = try DatabaseQueue(path: url.path)
    try Migrations.make().migrate(queue, upTo: "v3")
    try queue.write { d in
        try d.execute(sql: """
            INSERT INTO snapshots (captured_at, app, window_title, text, content_hash, source)
            VALUES (?, 'Notes', 'T', 'hello world', 'h1', 'ax')
            """, arguments: [Date(timeIntervalSince1970: 1_000)])
        var call = LLMCall.fixture()
        try call.insert(d)
    }
    try queue.close()

    let db = try AppDatabase.open(at: url)
    let (tables, indexes): ([String], [String]) = try db.reader.read { d in
        (try String.fetchAll(d, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"),
         try String.fetchAll(d, sql: "SELECT name FROM sqlite_master WHERE type = 'index'"))
    }
    #expect(try SnapshotStore(db).recent(limit: 5).count == 1)
    #expect(try LLMCallStore(db).calls(since: .distantPast, limit: 5).count == 1)
    for t in derivedMemoryTables + ["time_rules", "chronicle_fts", "wiki_pages_fts", "wiki_facts_fts"] {
        #expect(tables.contains(t), "missing table \(t)")
    }
    let statsColumns = try db.reader.read { try $0.columns(in: "boilerplate_stats").map(\.name) }
    #expect(statsColumns.contains("last_seen_at"))
    for i in ["jobs_on_status_next_run_at_priority", "chronicle_on_level_period_start", "wiki_pages_on_type",
              "wiki_pages_on_is_dirty", "wiki_pages_on_last_seen", "wiki_facts_on_slug_invalid_at", "wiki_facts_on_superseded_by",
              "salient_flags_on_status_kind", "salient_flags_on_due_at", "embeddings_on_model_id_revision"] {
        #expect(indexes.contains(i), "missing index \(i)")
    }
}

/// `name=value` from a `CREATE VIRTUAL TABLE … USING fts5(…)` statement (values hold no `,` or `)`).
private func ftsOption(_ name: String, in sql: String) -> String? {
    guard let r = sql.range(of: name + "=") else { return nil }
    return String(sql[r.lowerBound...].prefix { $0 != "," && $0 != ")" })
}

@Test func newFTSTablesUseV1TokenizerAndAreSynchronized() throws {
    let db = try AppDatabase.inMemory()
    let sql: [String: String] = try db.reader.read { d in
        let rows = try Row.fetchAll(d, sql: """
            SELECT name, sql FROM sqlite_master
            WHERE name IN ('snapshots_fts', 'chronicle_fts', 'wiki_pages_fts', 'wiki_facts_fts')
            """)
        return Dictionary(uniqueKeysWithValues: rows.map { ($0["name"] as String, $0["sql"] as String) })
    }
    let v1 = try #require(sql["snapshots_fts"])
    let tokenize = try #require(ftsOption("tokenize", in: v1))
    let prefix = try #require(ftsOption("prefix", in: v1))
    #expect(tokenize.contains("remove_diacritics") && prefix.contains("2 3"))
    for (table, content) in [("chronicle_fts", "chronicle"), ("wiki_pages_fts", "wiki_pages"),
                             ("wiki_facts_fts", "wiki_facts")] {
        let s = try #require(sql[table])
        #expect(ftsOption("tokenize", in: s) == tokenize, "\(table)")
        #expect(ftsOption("prefix", in: s) == prefix, "\(table)")
        #expect(ftsOption("content", in: s) == "content='\(content)'", "\(table)")
        #expect(ftsOption("content_rowid", in: s) == "content_rowid='id'", "\(table)")
    }
}

private func ftsCount(_ db: AppDatabase, _ table: String, _ match: String) throws -> Int {
    try db.reader.read { d in
        try Int.fetchOne(d, sql: "SELECT count(*) FROM \(table) WHERE \(table) MATCH ?", arguments: [match]) ?? 0
    }
}

@Test func chronicleFTSFindsAccentInsensitive() throws {
    let db = try AppDatabase.inMemory()
    try db.writer.write { d in
        var c = Chronicle.fixture(level: .day, key: "2026-11-20", summary: "Réunion à Oslo")
        try c.insert(d)
    }
    #expect(try ftsCount(db, "chronicle_fts", "reunion") == 1)
    #expect(try ftsCount(db, "chronicle_fts", "réunion") == 1)
    #expect(try ftsCount(db, "chronicle_fts", "reu*") == 1)
    #expect(try ftsCount(db, "chronicle_fts", "berlin") == 0)
    // Synchronized: an update re-indexes, a delete removes.
    try db.writer.write { d in try d.execute(sql: "UPDATE chronicle SET summary = 'Déjeuner à Berlin'") }
    #expect(try ftsCount(db, "chronicle_fts", "reunion") == 0)
    #expect(try ftsCount(db, "chronicle_fts", "dejeuner") == 1)
    try db.writer.write { d in _ = try Chronicle.deleteAll(d) }
    #expect(try ftsCount(db, "chronicle_fts", "dejeuner") == 0)
}

@Test func wikiFTSFindsAccentInsensitive() throws {
    let db = try AppDatabase.inMemory()
    try db.writer.write { d in
        var p = WikiPage.fixture(slug: "francois", title: "François Hébert", body: "Équipe produit")
        try p.insert(d)
        var f = WikiFact.fixture(slug: "francois", fact: "Il préfère le café", normKey: "il prefere le cafe")
        try f.insert(d)
    }
    #expect(try ftsCount(db, "wiki_pages_fts", "francois") == 1)
    #expect(try ftsCount(db, "wiki_pages_fts", "equipe") == 1)
    #expect(try ftsCount(db, "wiki_facts_fts", "prefere cafe") == 1)
    try db.writer.write { d in _ = try WikiPage.deleteAll(d) }  // facts cascade
    #expect(try ftsCount(db, "wiki_pages_fts", "francois") == 0)
    #expect(try ftsCount(db, "wiki_facts_fts", "cafe") == 0)
}

@Test func factCascadesWithPageAndFollowsSlugRename() throws {
    let db = try AppDatabase.inMemory()
    try db.writer.write { d in
        var p = WikiPage.fixture(slug: "ada"); try p.insert(d)
        var f = WikiFact.fixture(slug: "ada"); try f.insert(d)
        try d.execute(sql: "UPDATE wiki_pages SET slug = 'ada-lovelace' WHERE slug = 'ada'")
    }
    let slugs: [String] = try db.reader.read { try String.fetchAll($0, sql: "SELECT slug FROM wiki_facts") }
    #expect(slugs == ["ada-lovelace"])
    try db.writer.write { d in try d.execute(sql: "DELETE FROM wiki_pages WHERE slug = 'ada-lovelace'") }
    #expect(try db.reader.read { try WikiFact.fetchCount($0) } == 0)
    // A fact cannot point at a missing page.
    #expect(throws: DatabaseError.self) {
        try db.writer.write { d in var f = WikiFact.fixture(slug: "nobody"); try f.insert(d) }
    }
}

@Test func uniqueKeysEnforced() throws {
    let db = try AppDatabase.inMemory()
    try db.writer.write { d in
        var j = Job.fixture(kind: .hour, key: "k"); try j.insert(d)
        var c = Chronicle.fixture(level: .day, key: "2026-11-20"); try c.insert(d)
        // Same key, different kind / level: allowed.
        var j2 = Job.fixture(kind: .timeLedger, key: "k"); try j2.insert(d)
        var c2 = Chronicle.fixture(level: .month, key: "2026-11-20"); try c2.insert(d)
    }
    #expect(throws: DatabaseError.self) {
        try db.writer.write { d in var j = Job.fixture(kind: .hour, key: "k"); try j.insert(d) }
    }
    #expect(throws: DatabaseError.self) {
        try db.writer.write { d in var c = Chronicle.fixture(level: .day, key: "2026-11-20"); try c.insert(d) }
    }
    #expect(throws: DatabaseError.self) {
        try db.writer.write { d in
            var p = WikiPage.fixture(slug: "ada"); try p.insert(d)
            var p2 = WikiPage.fixture(slug: "ada"); try p2.insert(d)
        }
    }
    #expect(throws: DatabaseError.self) {
        try db.writer.write { d in
            var a = SalientFlag(kind: .todo, text: "a", owner: .user, dedupeKey: "dup", createdAt: memoryT0,
                                lastSeenAt: memoryT0)
            try a.insert(d)
            var b = a; b.id = nil; try b.insert(d)
        }
    }
}

@Test func checkConstraintsRejectUnknownValues() throws {
    let db = try AppDatabase.inMemory()
    let bad = [
        "INSERT INTO jobs (kind, period_key, status, priority, next_run_at, created_at, updated_at) VALUES ('hour', 'k', 'bogus', 2, '2026-01-01', '2026-01-01', '2026-01-01')",
        "INSERT INTO chronicle (level, period_key, period_start, period_end, summary, generated_at) VALUES ('decade', 'k', '2026-01-01', '2026-01-01', 's', '2026-01-01')",
        "INSERT INTO identity (body, source, created_at) VALUES ('b', 'robot', '2026-01-01')",
        "INSERT INTO wiki_pages (slug, type, title, first_seen, last_seen, updated_at) VALUES ('s', 'place', 't', '2026-01-01', '2026-01-01', '2026-01-01')",
    ]
    for sql in bad {
        #expect(throws: DatabaseError.self, "\(sql)") { try db.writer.write { try $0.execute(sql: sql) } }
    }
}

@Test func timeLedgerKeyTreatsEmptyProjectAndAppAsOneRow() throws {
    let db = try AppDatabase.inMemory()
    try db.writer.write { d in
        var r = TimeLedgerRow(hourStart: memoryT0, project: "", app: "", seconds: 10); try r.insert(d)
    }
    #expect(throws: DatabaseError.self) {
        try db.writer.write { d in
            var r = TimeLedgerRow(hourStart: memoryT0, project: "", app: "", seconds: 20); try r.insert(d)
        }
    }
    #expect(throws: DatabaseError.self) {  // NOT NULL: a NULL project would let duplicates through
        try db.writer.write {
            try $0.execute(sql: "INSERT INTO time_ledger (hour_start, project, app, seconds) VALUES (?, NULL, 'a', 1)",
                           arguments: [memoryT0])
        }
    }
}

@Test func llmCallDeletionNullsDerivedRowReference() throws {
    let db = try AppDatabase.inMemory()
    let call = try LLMCallStore(db).insert(.fixture())
    try db.writer.write { d in var c = Chronicle.fixture(llmCallID: call.id); try c.insert(d) }
    try db.writer.write { d in _ = try LLMCall.deleteAll(d) }
    let row = try db.reader.read { try Chronicle.fetchOne($0) }
    #expect(row != nil && row?.llmCallID == nil)
}

@Test func recordsRoundTripJSONColumns() throws {
    let db = try AppDatabase.inMemory()
    var c = Chronicle.fixture(level: .hour, key: "2026-11-20T14+0100")
    c.snapshotIDs = [3, 1, 2]
    c.childIDs = [7]
    c.isDirty = true
    c.metadata = Chronicle.Metadata(
        projects: [.init(name: "Remora", apps: ["Xcode"], domains: ["github.com"], share: 0.75)],
        highlights: ["shipped v4"], apps: ["Xcode"], entities: ["ada"], mergedHours: 2, entitiesDone: true)
    var p = WikiPage.fixture()
    p.aliases = ["Ada L."]
    p.links = ["remora"]
    try db.writer.write { d in try c.insert(d); try p.insert(d) }
    let (c2, p2) = try db.reader.read { d in
        (try Chronicle.fetchOne(d, key: c.id), try WikiPage.fetchOne(d, key: p.id))
    }
    #expect(c2 == c)
    #expect(p2 == p)
    let raw: String? = try db.reader.read { try String.fetchOne($0, sql: "SELECT snapshot_ids FROM chronicle") }
    #expect(raw == "[3,1,2]")
}

@Test func emptyMetadataDecodesToDefaults() throws {
    let db = try AppDatabase.inMemory()
    try db.writer.write { d in
        try d.execute(sql: """
            INSERT INTO chronicle (level, period_key, period_start, period_end, summary, generated_at)
            VALUES ('day', 'k', ?, ?, 's', ?)
            """, arguments: [memoryT0, memoryT0, memoryT0])
    }
    let c = try db.reader.read { try Chronicle.fetchOne($0) }
    #expect(c?.metadata == Chronicle.Metadata())
    #expect(c?.snapshotIDs == [] && c?.childIDs == [] && c?.isDirty == false)
}

@Test func chronicleLevelParentsAndJobPriorities() {
    #expect(ChronicleLevel.hour.parents == [.day])
    #expect(ChronicleLevel.day.parents == [.week, .month])
    #expect(ChronicleLevel.week.parents == [])
    #expect(ChronicleLevel.month.parents == [.year])
    #expect(ChronicleLevel.year.parents == [])
    let order: [JobKind] = [.workingMemory, .timeLedger, .hour, .dayRollup, .weekRollup, .monthRollup, .yearRollup,
                            .wikiRewrite, .embeddings, .styleNotes, .identity, .compaction]
    #expect(order.map(\.priority) == Array(0...11))
    #expect(JobKind.allCases.count == 17)
    #expect(JobKind.routineScan.priority == 12 && JobKind.routineScan.rawValue == "routine_scan")
    // The digest rebuild after a forget runs before everything else.
    #expect(JobKind.digestRebuild.priority == -3 && JobKind.digestRebuild.rawValue == "digest_rebuild")
    // Plan 5 proactive kinds run before every memory job.
    #expect(JobKind.morningBrief.priority == -2 && JobKind.eveningWrap.priority == -2 && JobKind.nudgeScan.priority == -1)
    #expect(JobKind.morningBrief.rawValue == "morning_brief" && JobKind.eveningWrap.rawValue == "evening_wrap"
            && JobKind.nudgeScan.rawValue == "nudge_scan")
    #expect(JobKind.workingMemory.rawValue == "working_memory" && JobKind.wikiRewrite.rawValue == "wiki_rewrite")
    #expect(Job.fixture(kind: .compaction).priority == 11)
}

@Test func deletingSupersedingFactNullsSupersededBy() throws {
    let db = try AppDatabase.inMemory()
    let (oldID, newID): (Int64, Int64) = try db.writer.write { d in
        var p = WikiPage.fixture(slug: "ada"); try p.insert(d)
        var new = WikiFact.fixture(fact: "Ada lives in Paris", normKey: "ada lives in paris"); try new.insert(d)
        var old = WikiFact.fixture(fact: "Ada lives in Lyon", normKey: "ada lives in lyon")
        old.supersededBy = new.id; try old.insert(d)
        return (old.id!, new.id!)
    }
    try db.writer.write { d in _ = try WikiFact.deleteOne(d, key: newID) }
    let old = try #require(try db.reader.read { try WikiFact.fetchOne($0, key: oldID) })
    #expect(old.supersededBy == nil)
    // `superseded_by` cannot point at a missing fact.
    #expect(throws: DatabaseError.self) {
        try db.writer.write { d in
            try d.execute(sql: "UPDATE wiki_facts SET superseded_by = 999 WHERE id = ?", arguments: [oldID])
        }
    }
}

/// Final review #4/#8 (v4 edited in place): tombstones hold no text; boilerplate stats carry
/// `last_seen_at`.
@Test func v4HasTombstonesWithoutTextAndBoilerplateLastSeen() throws {
    let db = try AppDatabase.inMemory()
    let (sources, stats) = try db.reader.read { d in
        (try d.columns(in: "snapshot_sources").map(\.name), try d.columns(in: "boilerplate_stats").map(\.name))
    }
    #expect(sources == ["id", "app", "bundle_id", "domain", "url_host"])
    #expect(stats.contains("last_seen_at"))
    #expect(DataReset.derivedMemoryTables.contains("snapshot_sources"))
}

/// Residual round #2: on a database v4 creates now, v4.1 is a no-op (both objects come from v4).
@Test func v41IsANoOpOnAFreshV4Database() throws {
    let url = tempDir().appending(path: "remora.sqlite")
    let queue = try DatabaseQueue(path: url.path)
    try Migrations.make().migrate(queue, upTo: "v4")
    let schema = { try queue.read { try String.fetchAll($0, sql: "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY name") } }
    let before = try schema()
    try Migrations.make().migrate(queue, upTo: "v4.1")
    #expect(try schema() == before)
    #expect(try queue.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations") }.contains("v4.1"))
}
