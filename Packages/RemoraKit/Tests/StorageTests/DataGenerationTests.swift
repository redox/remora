import Foundation
import GRDB
import Testing
@testable import Storage

@Test func generationStartsAtZero() throws {
    let db = try AppDatabase.inMemory()
    #expect(try DataGeneration.current(db) == 0)
}

@Test func generationWriteRunsBodyWhenCurrent() throws {
    let db = try AppDatabase.inMemory()
    let g = try DataGeneration.current(db)
    let id = try DataGeneration.write(db, expected: g) { d -> Int64? in
        var c = Chronicle.fixture(); try c.insert(d); return c.id
    }
    #expect(id != nil)
    #expect(try db.reader.read { try Chronicle.fetchCount($0) } == 1)
}

@Test func generationWriteRejectsStale() throws {
    let db = try AppDatabase.inMemory()
    let g = try DataGeneration.current(db)
    try DataReset.deleteAllCapturedData(in: db)
    #expect(try DataGeneration.current(db) == g + 1)
    var ran = false
    #expect(throws: DataGeneration.Stale()) {
        try DataGeneration.write(db, expected: g) { d in
            ran = true
            var c = Chronicle.fixture(); try c.insert(d)
            return 1
        }
    }
    #expect(!ran)
    #expect(try db.reader.read { try Chronicle.fetchCount($0) } == 0)
    // The new generation writes again.
    #expect(try DataGeneration.write(db, expected: g + 1) { _ in 7 } == 7)
}

@Test func generationReadsJSONSettingWrittenBySettingsStore() throws {
    let db = try AppDatabase.inMemory()
    try SettingsStore(db).setValue(41, forKey: DataGeneration.key)
    #expect(try DataGeneration.current(db) == 41)
    try db.writer.write { try DataGeneration.bump(in: $0) }
    #expect(try SettingsStore(db).value(Int.self, forKey: DataGeneration.key) == 42)
}

@Test func corruptGenerationFailsClosedAndDeleteAllRepairsIt() throws {
    let db = try AppDatabase.inMemory()
    try db.writer.write {
        try $0.execute(sql: "INSERT INTO settings (key, value) VALUES (?, 'garbage')", arguments: [DataGeneration.key])
    }
    #expect(throws: SettingsStore.CorruptValue.self) { try DataGeneration.current(db) }
    #expect(throws: SettingsStore.CorruptValue.self) { try DataGeneration.write(db, expected: 0) { _ in 1 } }
    try DataReset.deleteAllCapturedData(in: db)
    #expect(try DataGeneration.current(db) > 1)
}

/// A job may hold any generation read before the value went corrupt: the repair writes
/// `max(0, epoch-ms) + 1`, above every value a job could have read.
@Test func corruptGenerationRepairWritesValueNoJobHolds() throws {
    let db = try AppDatabase.inMemory()
    try SettingsStore(db).setValue(5, forKey: DataGeneration.key)
    let held = try DataGeneration.current(db)
    try db.writer.write {
        try $0.execute(sql: "UPDATE settings SET value = 'garbage' WHERE key = ?", arguments: [DataGeneration.key])
    }
    let now = Date(timeIntervalSince1970: 1_700_000_000.5)
    try db.writer.write { try DataGeneration.bump(in: $0, now: now) }
    #expect(try DataGeneration.current(db) == 1_700_000_000_500 + 1)
    #expect(throws: DataGeneration.Stale()) { try DataGeneration.write(db, expected: held) { _ in 1 } }
    #expect(throws: DataGeneration.Stale()) { try DataGeneration.write(db, expected: 1) { _ in 1 } }
}

/// `Int.max + 1` must not trap; the wrapped value differs from every value a job holds.
@Test func overflowingGenerationRepairDoesNotTrap() throws {
    let db = try AppDatabase.inMemory()
    try SettingsStore(db).setValue(Int.max, forKey: DataGeneration.key)
    let held = try DataGeneration.current(db)
    try DataReset.deleteAllCapturedData(in: db)
    let repaired = try DataGeneration.current(db)
    #expect(repaired == Int.max &+ 1)
    #expect(throws: DataGeneration.Stale()) { try DataGeneration.write(db, expected: held) { _ in 1 } }
    // The next bump continues from the repaired value.
    try db.writer.write { try DataGeneration.bump(in: $0) }
    #expect(try DataGeneration.current(db) == repaired + 1)
}

/// GRDB writes are not reentrant: store writes used by runners inside `DataGeneration.write`
/// have `in:` overloads that use the given connection (F-6, F-13).
@Test func storeOverloadsWriteInsideGenerationWrite() throws {
    let db = try AppDatabase.inMemory()
    let calls = LLMCallStore(db)
    let call = try calls.insert(.fixture())
    let callID = try #require(call.id)
    try DataGeneration.write(db, expected: 0) { d in
        try calls.setArtifact(callID: callID, table: "wiki_pages", id: nil, in: d)
        try SettingsStore(db).setValue("fr", forKey: "memory.language", in: d)
        #expect(try SettingsStore(db).value(String.self, forKey: "memory.language", in: d) == "fr")
        try StyleNoteStore(db).upsert(surface: "mail", notes: "short", llmCallID: callID, at: memoryT0, in: d)
    }
    let row = try #require(try calls.calls(since: .distantPast, limit: 1).first)
    #expect(row.artifactTable == "wiki_pages" && row.artifactID == nil)
    #expect(try SettingsStore(db).value(String.self, forKey: "memory.language") == "fr")
    #expect(try StyleNoteStore(db).note(for: "mail") == "short")
    // The non-`in:` forms still work and forward.
    try calls.setArtifact(callID: callID, table: "chronicle", id: 9)
    let again = try #require(try calls.calls(since: .distantPast, limit: 1).first)
    #expect(again.artifactTable == "chronicle" && again.artifactID == 9)
}
