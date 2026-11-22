import Foundation
import Testing
@testable import Storage

@Test func insertRecentAndRecordOutcome() throws {
    let db = try AppDatabase.inMemory()
    let s = InlineOutputStore(db)
    let a = try s.insert(.fixture(at: Date(timeIntervalSince1970: 1_000)))
    let b = try s.insert(.fixture(mode: .edit, at: Date(timeIntervalSince1970: 2_000)))
    #expect(try s.recent(limit: 5).map(\.id) == [b.id, a.id])
    let checked = Date(timeIntervalSince1970: 3_000)
    try s.recordOutcome(id: a.id!, outcome: .edited, finalText: "final", at: checked)
    let back = try #require(try s.recent(limit: 5).last)
    #expect(back.outcome == .edited && back.finalText == "final" && back.checkedAt == checked)
    #expect(back.mode == .selection)
    try s.recordOutcome(id: a.id!, outcome: nil, finalText: nil, at: checked)
    #expect(try s.recent(limit: 5).last?.outcome == nil)
}

@Test func styleNotesUpsertPerSurface() throws {
    let db = try AppDatabase.inMemory()
    let s = StyleNoteStore(db)
    #expect(try s.note(for: "mail") == nil)
    try s.upsert(surface: "mail", notes: "formal", llmCallID: nil, at: Date(timeIntervalSince1970: 1))
    try s.upsert(surface: "mail", notes: "terse", llmCallID: nil, at: Date(timeIntervalSince1970: 2))
    try s.upsert(surface: "chat", notes: "casual", llmCallID: nil, at: Date(timeIntervalSince1970: 2))
    #expect(try s.note(for: "mail") == "terse" && s.note(for: "chat") == "casual")
}
