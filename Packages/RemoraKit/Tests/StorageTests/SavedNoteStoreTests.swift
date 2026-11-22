import Foundation
import Testing
@testable import Storage

@Test func savedNotesAreRemovedFromSearchAndChatReplay() throws {
    let db = try AppDatabase.inMemory()
    let store = SavedNoteStore(db)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let note = SavedNote(text: "Migrate API", annotation: "compatibility", createdAt: now)
    try db.writer.write { try SavedNoteStore.insert(note, in: $0) }
    try store.setChatAccess(true)
    #expect(try store.list(query: "compatibility").map(\.id) == [note.id])
    try store.delete(note.id, now: now)
    #expect(try store.list(query: "compatibility").isEmpty)
    #expect(try db.reader.read { ForgetMarks.chatForgetAt(in: $0) } == now)
}

@Test func resetClearsSavedNotesAndTheirIndex() throws {
    let db = try AppDatabase.inMemory()
    let store = SavedNoteStore(db)
    let note = SavedNote(text: "Migrate API", annotation: "", createdAt: Date())
    try db.writer.write { try SavedNoteStore.insert(note, in: $0) }
    try store.setChatAccess(true)
    try DataReset.deleteAllCapturedData(in: db)
    #expect(try store.list().isEmpty)
    #expect(try db.reader.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM saved_notes_fts_docsize") } == 0)
    #expect(try !store.chatAccessEnabled())
}
