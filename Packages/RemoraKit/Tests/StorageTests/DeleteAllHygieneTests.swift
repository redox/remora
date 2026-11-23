import Foundation
import GRDB
import Testing
@testable import Storage

private func fileContains(_ url: URL, _ marker: String) -> Bool {
    guard let data = try? Data(contentsOf: url) else { return false }
    return data.range(of: Data(marker.utf8)) != nil
}

/// After "Delete all data", no byte of previously captured text may remain in the database
/// file or its WAL (secure_delete, FTS delete-all, VACUUM, checkpoint TRUNCATE).
@Test func deleteAllLeavesNoRecoverableBytes() throws {
    let url = tempDir().appending(path: "remora.sqlite")
    let wal = URL(filePath: url.path + "-wal")
    let marker = "zqxjmarkerqq7781"
    let db = try AppDatabase.open(at: url)
    let store = SnapshotStore(db)
    for i in 0..<50 {
        _ = try store.insert(Snapshot(
            capturedAt: Date(timeIntervalSince1970: 1_000 + Double(i)), app: "Notes",
            windowTitle: "title \(marker) \(i)", url: "https://example.com/\(marker)",
            text: String(repeating: "filler text \(marker) number \(i) ", count: 40),
            contentHash: "h\(i)", source: .ax))
    }
    try ActivityStore(db).recordFocus(app: "Notes", bundleID: nil, windowTitle: "w \(marker)",
                                      domain: nil, at: Date(timeIntervalSince1970: 1_000))
    // Derived memory (plan 4) holds captured text too, including three FTS indexes.
    try seedMemoryRows(db, marker: marker)
    // Chat, inbox, reminders and nudge decisions (plan 5) hold user and model text.
    try seedAssistantRows(db, marker: marker)
    // Half the data checkpointed into the main file, the rest still in the WAL.
    try db.writer.writeWithoutTransaction { try $0.execute(sql: "PRAGMA wal_checkpoint(PASSIVE)") }
    try ExclusionStore(db).add("app:Keep")
    #expect(fileContains(url, marker) || fileContains(wal, marker))

    try DataReset.deleteAllCapturedData(in: db)

    #expect(!fileContains(url, marker), "main database file still holds captured bytes")
    #expect(!fileContains(wal, marker), "WAL still holds captured bytes")
    #expect(try ExclusionStore(db).all() == ["app:Keep"])
    #expect(try store.search(marker).isEmpty)
    // The database stays usable.
    _ = try store.insert(.fixture(text: "after delete"))
    #expect(try store.recent(limit: 5).count == 1)
}

// MARK: - Partial failure: deleted, cleanup pending (re-review minor)

private struct ScrubBoom: Error {}

private func seeded() throws -> AppDatabase {
    let db = try AppDatabase.inMemory()
    _ = try SnapshotStore(db).insert(.fixture(text: "hello world"))
    try ActivityStore(db).recordFocus(app: "A", bundleID: nil, windowTitle: nil, domain: nil,
                                      at: Date(timeIntervalSince1970: 1_000))
    return db
}

@Test func scrubFailureAfterCommitIsCleanupPendingAndRetried() throws {
    let db = try seeded()
    var attempts = 0
    #expect(throws: DataReset.CleanupPending.self) {
        try DataReset.deleteAllCapturedData(in: db, scrub: { _ in attempts += 1; throw ScrubBoom() })
    }
    #expect(attempts == 2)  // tried, then retried once immediately
    #expect(try SnapshotStore(db).recent(limit: 5).isEmpty)  // the delete itself committed
    #expect(try ActivityStore(db).events(since: .distantPast).isEmpty)
    #expect(try DataReset.isScrubPending(in: db))
    // Next launch: the pending scrub runs and clears the flag.
    var ran = 0
    #expect(try DataReset.scrubIfPending(in: db, scrub: { _ in ran += 1 }) == true)
    let stillPending = try DataReset.isScrubPending(in: db)
    #expect(ran == 1 && !stillPending)
    #expect(try DataReset.scrubIfPending(in: db) == false)
}

@Test func failedDeleteIsNotCleanupPendingAndRemovesNothing() throws {
    let db = try seeded()
    try db.writer.write { try $0.execute(sql: "DROP TABLE activity_events") }
    do {
        try DataReset.deleteAllCapturedData(in: db)
        Issue.record("expected an error")
    } catch {
        #expect(!(error is DataReset.CleanupPending))
    }
    #expect(try SnapshotStore(db).recent(limit: 5).count == 1)  // rolled back
    let pending = try DataReset.isScrubPending(in: db)
    #expect(!pending)
}

@Test func successfulDeleteLeavesNoPendingScrub() throws {
    let db = try seeded()
    try DataReset.deleteAllCapturedData(in: db)
    let pending = try DataReset.isScrubPending(in: db)
    #expect(!pending)
}

@Test func deleteAllRemovesInlineOutputsAndStyleNotesKeepsCalls() throws {
    let db = try AppDatabase.inMemory()
    let call = try LLMCallStore(db).insert(.fixture())
    _ = try InlineOutputStore(db).insert(.fixture(llmCallID: call.id))
    try StyleNoteStore(db).upsert(surface: "mail", notes: "n", llmCallID: call.id, at: Date())
    try DataReset.deleteAllCapturedData(in: db)
    #expect(try InlineOutputStore(db).recent(limit: 5).isEmpty)
    #expect(try StyleNoteStore(db).note(for: "mail") == nil)
    #expect(try LLMCallStore(db).calls(since: .distantPast, limit: 5).count == 1)
}

@Test func deleteAllWipesDerivedAndBumpsGeneration() throws {
    let db = try AppDatabase.inMemory()
    try seedMemoryRows(db)
    let settings = SettingsStore(db)
    try db.writer.write { d in
        var user = TimeRule(project: "Remora", app: "Xcode", source: "user", createdAt: memoryT0)
        try user.insert(d)
        var auto = TimeRule(project: "Other", domain: "example.com", source: "auto", createdAt: memoryT0)
        try auto.insert(d)
    }
    try settings.setValue("fr", forKey: "memory.language")
    try settings.setValue(false, forKey: "memory.enabled")
    try settings.setValue(["days": 7], forKey: "memory.retention")
    let cleared = ["memory.plannerWatermark", "memory.wm.lastSnapshotAt", "memory.compaction.last",
                   "memory.backoff", "memory.lastStyleRunAt"]
    for key in cleared { try settings.setValue(memoryT0, forKey: key) }
    let before = try DataGeneration.current(db)
    for t in derivedMemoryTables {
        #expect(try db.reader.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM \(t)") } == 1, "\(t)")
    }

    try DataReset.deleteAllCapturedData(in: db)

    for t in derivedMemoryTables {
        #expect(try db.reader.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM \(t)") } == 0, "\(t)")
    }
    for fts in ["chronicle_fts", "wiki_pages_fts", "wiki_facts_fts"] {
        let (hits, docs): (Int?, Int?) = try db.reader.read { d in
            (try Int.fetchOne(d, sql: "SELECT count(*) FROM \(fts) WHERE \(fts) MATCH 'memmarker'"),
             try Int.fetchOne(d, sql: "SELECT count(*) FROM \(fts)_docsize"))
        }
        #expect(hits == 0 && docs == 0, "\(fts)")
    }
    let rules = try db.reader.read { try TimeRule.fetchAll($0) }
    #expect(rules.map(\.source) == ["user"])
    #expect(try settings.value(String.self, forKey: "memory.language") == "fr")
    #expect(try settings.value(Bool.self, forKey: "memory.enabled") == false)
    #expect(try settings.value([String: Int].self, forKey: "memory.retention") == ["days": 7])
    for key in cleared { #expect(try settings.value(Date.self, forKey: key) == nil, "\(key)") }
    #expect(try DataGeneration.current(db) == before + 1)
    #expect(try LLMCallStore(db).calls(since: .distantPast, limit: 5).count == 1)
}

@Test func failedDeleteKeepsDerivedMemoryAndGeneration() throws {
    let db = try seeded()
    try seedMemoryRows(db)
    try db.writer.write { try $0.execute(sql: "DROP TABLE memory_digest") }
    #expect(throws: (any Error).self) { try DataReset.deleteAllCapturedData(in: db) }
    #expect(try db.reader.read { try Chronicle.fetchCount($0) } == 1)
    #expect(try SnapshotStore(db).recent(limit: 5).count == 1)
    #expect(try DataGeneration.current(db) == 0)
}

// MARK: - Plan 5 assistant tables

@Test func deleteAllWipesAssistantTables() throws {
    let db = try AppDatabase.inMemory()
    try seedAssistantRows(db)
    for t in assistantTables { #expect(try rowCount(db, t) == 1, "\(t)") }
    let before = try DataGeneration.current(db)
    try ExclusionStore(db).add("app:Keep")

    try DataReset.deleteAllCapturedData(in: db)

    for t in assistantTables { #expect(try rowCount(db, t) == 0, "\(t)") }
    #expect(try DataGeneration.current(db) == before + 1)
    #expect(try LLMCallStore(db).calls(since: .distantPast, limit: 5).count == 1)
    #expect(try ExclusionStore(db).all() == ["app:Keep"])
}

@Test func deleteAllClearsDerivedSettings() throws {
    let db = try AppDatabase.inMemory()
    try db.writer.write { d in
        try ForgetMarks.mark(now: memoryT0, in: d)
        try SettingsStore(db).setValue([["reminderID": 1]], forKey: "reminders.pendingPrompts", in: d)
        try SettingsStore(db).setValue(["sample": RoutineFeedback.dismissed], forKey: RoutineFeedback.settingsKey, in: d)
        try SettingsStore(db).setValue(["sample": memoryT0], forKey: RoutineFindings.seenKey, in: d)
    }
    try DataReset.deleteAllCapturedData(in: db)
    for key in [ForgetMarks.digestDirtyKey, ForgetMarks.chatForgetAtKey, "reminders.pendingPrompts",
                RoutineFeedback.settingsKey, RoutineFindings.seenKey] {
        let raw = try db.reader.read { try String.fetchOne($0, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key]) }
        #expect(raw == nil, "\(key)")
    }
}

@Test func forgettingCapturesClearsRoutineFeedback() throws {
    let db = try AppDatabase.inMemory()
    let settings = SettingsStore(db)
    try settings.setValue(["sample": RoutineFeedback.label("Weekly check-in")], forKey: RoutineFeedback.settingsKey)
    try db.writer.write { try ForgetMarks.mark(now: memoryT0, in: $0) }
    #expect(try settings.value([String: RoutineFeedback].self, forKey: RoutineFeedback.settingsKey) == nil)
}

/// The assistant tables are wiped in the same transaction as the generation bump: a failure
/// rolls both back.
@Test func failedDeleteKeepsAssistantTables() throws {
    let db = try seeded()
    try seedAssistantRows(db)
    try db.writer.write { try $0.execute(sql: "DROP TABLE memory_digest") }
    #expect(throws: (any Error).self) { try DataReset.deleteAllCapturedData(in: db) }
    for t in assistantTables { #expect(try rowCount(db, t) == 1, "\(t)") }
    #expect(try DataGeneration.current(db) == 0)
}
