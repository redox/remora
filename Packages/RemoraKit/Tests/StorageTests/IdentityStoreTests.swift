import Foundation
import Testing
@testable import Storage

private func at(_ s: Double) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + s) }

@Test func unchangedUserSaveIsNoOp() throws {
    let db = try AppDatabase.inMemory()
    let store = IdentityStore(db)
    let first = try store.saveUserEdit("I am Léa.\nI design.", at: at(0))
    let again = try store.saveUserEdit("  I am Léa.\nI design.\n", at: at(10))
    #expect(again == first)
    #expect(try store.history(limit: 10).count == 1)
    let changed = try store.saveUserEdit("I am Léa.", at: at(20))
    #expect(changed.id != first.id && changed.source == .user)
    #expect(try store.current() == changed)
}

@Test func historyIsNewestFirstAndLimited() throws {
    let db = try AppDatabase.inMemory()
    let store = IdentityStore(db)
    _ = try store.saveUserEdit("one", at: at(0))
    _ = try db.writer.write { d in try store.insertLLM("two", llmCallID: nil, at: at(10), in: d) }
    _ = try store.saveUserEdit("three", at: at(20))
    #expect(try store.history(limit: 10).map(\.body) == ["three", "two", "one"])
    #expect(try store.history(limit: 2).map(\.body) == ["three", "two"])
}

@Test func lastLLMAndLatestUserAfterIt() throws {
    let db = try AppDatabase.inMemory()
    let store = IdentityStore(db)
    #expect(try store.current() == nil && store.lastLLMRevision() == nil)
    let user1 = try store.saveUserEdit("u1", at: at(0))
    #expect(try store.latestUserRevisionAfterLastLLM() == user1)
    let callID = try #require(try LLMCallStore(db).insert(.fixture(job: "identity")).id)
    let llm = try db.writer.write { d in try store.insertLLM("l1", llmCallID: callID, at: at(10), in: d) }
    #expect(try store.lastLLMRevision() == llm && llm.llmCallID == callID)
    #expect(try store.latestUserRevisionAfterLastLLM() == nil)
    let user2 = try store.saveUserEdit("u2", at: at(20))
    #expect(try store.latestUserRevisionAfterLastLLM() == user2)
}

@Test func inlineOutputsSinceIsOldestFirstAndExclusive() throws {
    let db = try AppDatabase.inMemory()
    let s = InlineOutputStore(db)
    for i in 0..<5 { _ = try s.insert(.fixture(original: "o\(i)", at: at(Double(i) * 10))) }
    #expect(try s.since(nil, limit: 10).map(\.original) == ["o0", "o1", "o2", "o3", "o4"])
    #expect(try s.since(at(10), limit: 10).map(\.original) == ["o2", "o3", "o4"])
    #expect(try s.since(at(10), limit: 2).map(\.original) == ["o2", "o3"])
}

@Test func styleNotesAllListsEverySurfaceIncludingStar() throws {
    let db = try AppDatabase.inMemory()
    let s = StyleNoteStore(db)
    try s.upsert(surface: "slack", notes: "- a\n", llmCallID: nil, at: at(0))
    let callID = try #require(try LLMCallStore(db).insert(.fixture(job: "style_consolidation")).id)
    try s.upsert(surface: "*", notes: "- b\n", llmCallID: callID, at: at(1))
    let all = try s.all()
    #expect(Set(all.map(\.surface)) == ["slack", "*"])
    #expect(all.first { $0.surface == "*" }?.notes == "- b\n")
    let row = try #require(try s.row(for: "*"))
    #expect(row.llmCallID == callID)
}

@Test func aUserEditWithNilCallIDMakesAnLLMNoteUserOwned() throws {
    let db = try AppDatabase.inMemory()
    let s = StyleNoteStore(db)
    let callID = try #require(try LLMCallStore(db).insert(.fixture(job: "style_consolidation")).id)
    try s.upsert(surface: "slack", notes: "- model\n", llmCallID: callID, at: at(0))
    #expect(try s.row(for: "slack")?.llmCallID == callID)
    try s.upsert(surface: "slack", notes: "- typed by the user\n", llmCallID: nil, at: at(10))
    #expect(try s.row(for: "slack")?.llmCallID == nil)
}
