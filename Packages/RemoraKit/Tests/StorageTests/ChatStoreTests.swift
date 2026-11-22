import Foundation
import GRDB
import Testing
@testable import Storage

@Test func resendingRemovesOnlyTheLatestExchange() throws {
    let db = try AppDatabase.inMemory(), store = ChatStore(db)
    let turns = try appendTurns(store, 4)
    try db.writer.write { try store.prepareForResend(userTurnID: turns[2].id!, in: $0) }
    #expect(try store.turns(limit: 20) == Array(turns.prefix(2)))
}

@Test func resendingRejectsAnOlderOrDeletedMessageWithoutChangingHistory() throws {
    let db = try AppDatabase.inMemory(), store = ChatStore(db)
    let turns = try appendTurns(store, 4)
    #expect(throws: ChatStore.EditError.self) {
        try db.writer.write { try store.prepareForResend(userTurnID: turns[0].id!, in: $0) }
    }
    #expect(try store.turns(limit: 20) == turns)
    try store.clear()
    #expect(throws: ChatStore.EditError.self) {
        try db.writer.write { try store.prepareForResend(userTurnID: turns[2].id!, in: $0) }
    }
    #expect(try store.turns(limit: 20).isEmpty)
}

@Test func resendingRefusesAPendingReply() throws {
    let db = try AppDatabase.inMemory(), store = ChatStore(db)
    let user = try store.append(.fixture(role: .user, text: "Question"))
    try store.append(.fixture(role: .assistant, text: "", status: .pending))
    #expect(throws: ChatStore.EditError.self) {
        try db.writer.write { try store.prepareForResend(userTurnID: user.id!, in: $0) }
    }
    #expect(try store.turns(limit: 20).count == 2)
}

@Test func resendingInvalidatesSummariesContainingTheOldMessage() throws {
    let db = try AppDatabase.inMemory(), store = ChatStore(db)
    let turns = try appendTurns(store, 4)
    try store.fold(throughTurnID: turns[1].id!, summary: "Earlier", llmCallID: nil, at: assistantT0)
    try store.fold(throughTurnID: turns[3].id!, summary: "Includes old question", llmCallID: nil, at: assistantT0)
    try db.writer.write { try store.prepareForResend(userTurnID: turns[2].id!, in: $0) }
    #expect(try store.latestSummary()?.body == "Earlier")
    #expect(try store.turns(limit: 20).allSatisfy(\.folded))
}

@Test func resendingKeepsCompletedActionReceiptsAndTheirIdentity() throws {
    let db = try AppDatabase.inMemory(), store = ChatStore(db)
    let user = try store.append(.fixture(role: .user, text: "Old question"))
    var answer = ChatTurn.fixture(role: .assistant, text: "Old reply")
    answer.tools = [ToolTrace(name: "set_reminder", ok: true, receipt: "Reminder created")]
    answer.llmCallIDs = [7]
    answer = try store.append(answer)
    try db.writer.write { try store.prepareForResend(userTurnID: user.id!, in: $0) }
    let kept = try #require(try store.turns(limit: 20).first)
    #expect(kept.id == answer.id && kept.tools == answer.tools && kept.llmCallIDs == [7])
    #expect(kept.text.contains("Reminder created") && !kept.text.contains("Old reply"))
    #expect(kept.tainted)
}

@Test func resendingPreservesInboxMessagesDeliveredAfterTheQuestion() throws {
    let db = try AppDatabase.inMemory(), store = ChatStore(db)
    let user = try store.append(.fixture(role: .user, text: "Question"))
    try store.append(.fixture(role: .assistant, text: "Reply"))
    let delivered = try db.writer.write { d in
        let inbox = try InboxStore(db).insertIfNew(.fixture(key: "delivery"), in: d)!
        return try store.append(ChatTurn(createdAt: assistantT0, role: .assistant, text: "Reminder",
                                        status: .complete, inboxID: inbox.id), in: d)
    }
    try db.writer.write { try store.prepareForResend(userTurnID: user.id!, in: $0) }
    #expect(try store.turns(limit: 20) == [delivered])
}

@Test func failedReplacementTransactionRestoresTheOriginalExchange() throws {
    enum Failure: Error { case save }
    let db = try AppDatabase.inMemory(), store = ChatStore(db)
    let turns = try appendTurns(store, 2)
    #expect(throws: Failure.self) {
        try db.writer.write { d in
            try store.prepareForResend(userTurnID: turns[0].id!, in: d)
            throw Failure.save
        }
    }
    #expect(try store.turns(limit: 20) == turns)
}

private func appendTurns(_ store: ChatStore, _ n: Int, from start: Date = assistantT0) throws -> [ChatTurn] {
    try (0..<n).map { i in
        try store.append(.fixture(role: i.isMultiple(of: 2) ? .user : .assistant, text: "t\(i)",
                                  at: start.addingTimeInterval(Double(i))))
    }
}

@Test func foldMarksTurnsAndStoresSummary() throws {
    let db = try AppDatabase.inMemory()
    let store = ChatStore(db)
    let turns = try appendTurns(store, 5)
    #expect(turns.allSatisfy { $0.id != nil })
    #expect(try store.latestSummary() == nil)
    #expect(try store.unfolded().map(\.id) == turns.map(\.id))

    let call = try LLMCallStore(db).insert(.fixture(job: "chat_fold"))
    try store.fold(throughTurnID: turns[2].id!, summary: "s", llmCallID: call.id, at: assistantT0.addingTimeInterval(60))

    #expect(try store.unfolded().map(\.id) == turns.suffix(2).map(\.id))
    let summary = try #require(try store.latestSummary())
    #expect(summary.body == "s" && summary.throughTurnID == turns[2].id && summary.llmCallID == call.id)
    // A second fold: the latest summary is the newest one.
    try store.fold(throughTurnID: turns[3].id!, summary: "s2", llmCallID: nil, at: assistantT0.addingTimeInterval(120))
    #expect(try store.latestSummary()?.body == "s2")
    #expect(try store.unfolded().map(\.id) == [turns[4].id])
}

@Test func failPendingAtLaunch() throws {
    let db = try AppDatabase.inMemory()
    let store = ChatStore(db)
    let user = try store.append(.fixture(role: .user, text: "q"))
    let pending = try store.append(.fixture(role: .assistant, text: "partial", status: .pending,
                                            at: assistantT0.addingTimeInterval(1)))
    // Every pending turn is interrupted, whatever its timestamp (clock changes included).
    let other = try store.append(.fixture(role: .assistant, text: "", status: .pending,
                                          at: assistantT0.addingTimeInterval(100)))

    #expect(try store.failPending(at: assistantT0.addingTimeInterval(50)) == 2)

    let rows = try store.turns(limit: 10)
    let failed = try #require(rows.first { $0.id == pending.id })
    #expect(failed.status == .failed && failed.error == "interrupted" && failed.text == "partial")
    #expect(rows.first { $0.id == user.id }?.status == .complete)
    #expect(rows.first { $0.id == other.id }?.status == .failed)
    #expect(try store.failPending(at: assistantT0.addingTimeInterval(60)) == 0)
}

@Test func turnsPageChronologically() throws {
    let db = try AppDatabase.inMemory()
    let store = ChatStore(db)
    let turns = try appendTurns(store, 6)
    // No cursor: the newest `limit`, oldest first.
    #expect(try store.turns(limit: 3).map(\.text) == ["t3", "t4", "t5"])
    // After a cursor: the next `limit` after it, oldest first.
    #expect(try store.turns(after: turns[0].id, limit: 2).map(\.text) == ["t1", "t2"])
    #expect(try store.turns(after: turns[5].id, limit: 2).isEmpty)
}

@Test func updateRewritesATurn() throws {
    let db = try AppDatabase.inMemory()
    let store = ChatStore(db)
    var turn = try store.append(.fixture(role: .assistant, text: "", status: .pending))
    turn.text = "answer"
    turn.status = .complete
    turn.tools = [ToolTrace(name: "get_usage", ok: true, confirmed: nil, receipt: nil)]
    turn.llmCallIDs = [7]
    try store.update(turn)
    #expect(try store.turns(limit: 1) == [turn])
}

/// B.29: a turn wiped mid-stream (delete-all, clear) is never re-inserted by a late update.
@Test func updateOfWipedTurnIsANoOp() throws {
    let db = try AppDatabase.inMemory()
    let store = ChatStore(db)
    var turn = try store.append(.fixture(role: .assistant, text: "", status: .pending))
    try DataReset.deleteAllCapturedData(in: db)
    turn.text = "late answer"
    turn.status = .complete
    try store.update(turn)
    #expect(try rowCount(db, "chat_turns") == 0)
    var other = try store.append(.fixture(role: .assistant, text: "", status: .pending))
    try store.clear()
    other.text = "late"
    try store.update(other)
    #expect(try rowCount(db, "chat_turns") == 0)
}

@Test func pruneDropsOldTurnsAndInbox() throws {
    let db = try AppDatabase.inMemory()
    let store = ChatStore(db)
    let now = assistantT0
    let old = now.addingTimeInterval(-100 * 86_400)
    let recent = now.addingTimeInterval(-10 * 86_400)
    let oldTurn = try store.append(.fixture(text: "old", at: old))
    _ = try store.append(.fixture(text: "recent", at: recent))
    try store.fold(throughTurnID: oldTurn.id!, summary: "old summary", llmCallID: nil, at: old)
    let settings = SettingsStore(db)
    try settings.setValue(["old": old, "recent": recent], forKey: RoutineFindings.seenKey)
    try db.writer.write { d in
        _ = try InboxStore(db).insertIfNew(.fixture(key: "old", at: old), in: d)
        _ = try InboxStore(db).insertIfNew(.fixture(key: "recent", at: recent), in: d)
    }

    let removed = try store.prune(olderThan: now.addingTimeInterval(-90 * 86_400))

    #expect(removed == 3)  // one turn, one summary, one inbox row
    #expect(try store.turns(limit: 10).map(\.text) == ["recent"])
    #expect(try store.latestSummary() == nil)
    let keys = try db.reader.read { try String.fetchAll($0, sql: "SELECT dedupe_key FROM inbox_messages") }
    #expect(keys == ["recent"])
    #expect(try settings.value([String: Date].self, forKey: RoutineFindings.seenKey) == ["recent": recent])
}

@Test func clearEmptiesTurnsSummariesAndInboxOnly() throws {
    let db = try AppDatabase.inMemory()
    try seedAssistantRows(db)
    try ChatStore(db).clear()
    for t in ["chat_turns", "chat_summaries", "inbox_messages"] { #expect(try rowCount(db, t) == 0, "\(t)") }
    #expect(try rowCount(db, "reminders") == 1)
    #expect(try rowCount(db, "nudge_decisions") == 1)
}

/// Inbox delivery (Task 6) appends the assistant turn inside its own write.
@Test func appendInsideATransaction() throws {
    let db = try AppDatabase.inMemory()
    let store = ChatStore(db)
    let turn = try db.writer.write { d in try store.append(.fixture(text: "in tx"), in: d) }
    #expect(turn.id != nil)
    #expect(try store.turns(limit: 5).map(\.text) == ["in tx"])
}

/// Fix round 1: a fold whose turns were wiped during the LLM call stores nothing.
@Test func foldAfterWipeIsANoOp() throws {
    let db = try AppDatabase.inMemory()
    let store = ChatStore(db)
    var turns = try appendTurns(store, 3)
    try DataReset.deleteAllCapturedData(in: db)
    try store.fold(throughTurnID: turns[1].id!, summary: "stale", llmCallID: nil, at: assistantT0)
    #expect(try rowCount(db, "chat_summaries") == 0)
    #expect(try store.latestSummary() == nil)

    turns = try appendTurns(store, 3)
    try store.clear()
    let fresh = try store.append(.fixture(text: "after clear"))
    try db.writer.write { d in
        try store.fold(throughTurnID: turns[2].id!, summary: "stale", llmCallID: nil, at: assistantT0, in: d)
    }
    #expect(try rowCount(db, "chat_summaries") == 0)
    // The turn written after the clear stays unfolded (ids are never reused).
    #expect(try store.unfolded().map(\.id) == [fresh.id])
    #expect(fresh.id! > turns[2].id!)
}

@Test func taintedRoundTripsAndHistoryReadsInOneConnection() throws {
    let db = try AppDatabase.inMemory()
    let store = ChatStore(db)
    var t = try store.append(ChatTurn(createdAt: assistantT0, role: .assistant, text: "a", status: .pending))
    #expect(try store.unfolded().first?.tainted == false)
    t.tainted = true
    t.status = .complete
    try store.update(t)
    let (turns, summary) = try db.reader.read { d in (try store.unfolded(in: d), try store.latestSummary(in: d)) }
    #expect(turns.map(\.tainted) == [true])
    #expect(summary == nil)
}
