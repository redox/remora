import Foundation
import GRDB
import Testing
@testable import Storage

private func nudge(_ key: String, at: Date) -> InboxMessage { .fixture(kind: .nudge, key: key, at: at) }

private func seedNudges(_ db: AppDatabase, _ times: [Date]) throws {
    try db.writer.write { d in
        for (i, at) in times.enumerated() { _ = try InboxStore(db).insertIfNew(nudge("seed\(i)", at: at), in: d) }
    }
}

@Test func inboxDedupes() throws {
    let db = try AppDatabase.inMemory()
    let store = InboxStore(db)
    let first = try db.writer.write { try store.insertIfNew(.fixture(key: "morning:2026-11-20"), in: $0) }
    let second = try db.writer.write {
        try store.insertIfNew(.fixture(key: "morning:2026-11-20", body: "other"), in: $0)
    }
    #expect(first?.id != nil)
    #expect(second == nil)
    #expect(try rowCount(db, "inbox_messages") == 1)
    let body = try db.reader.read { try String.fetchOne($0, sql: "SELECT body FROM inbox_messages") }
    #expect(body == "body")
}

@Test func nudgeCapIsAtomic() async throws {
    let db = try AppDatabase.inMemory()
    let store = InboxStore(db)
    let dayStart = assistantT0
    try seedNudges(db, [dayStart.addingTimeInterval(3_600), dayStart.addingTimeInterval(7_200)])
    let now = dayStart.addingTimeInterval(36_000)
    async let a = Task.detached {
        try db.writer.write { d in
            try store.insertNudge(nudge("a", at: now), dailyCap: 3, minGap: 0, dayStart: dayStart, in: d)
        }
    }.value
    async let b = Task.detached {
        try db.writer.write { d in
            try store.insertNudge(nudge("b", at: now), dailyCap: 3, minGap: 0, dayStart: dayStart, in: d)
        }
    }.value
    let results = try await [a, b]
    #expect(results.compactMap { $0 }.count == 1)
    #expect(try store.nudgeCount(since: dayStart) == 3)
    // Nudges before the day start do not count toward its cap.
    #expect(try store.nudgeCount(since: now.addingTimeInterval(1)) == 0)
}

@Test func nudgeGapEnforced() throws {
    let db = try AppDatabase.inMemory()
    let store = InboxStore(db)
    let dayStart = assistantT0
    let last = dayStart.addingTimeInterval(10 * 3_600)
    try db.writer.write { d in _ = try store.insertIfNew(nudge("last", at: last), in: d) }
    #expect(try store.lastNudgeAt() == last)

    let tooSoon = try db.writer.write { d in
        try store.insertNudge(nudge("soon", at: last.addingTimeInterval(30 * 60)), dailyCap: 3, minGap: 5_400,
                              dayStart: dayStart, in: d)
    }
    #expect(tooSoon == nil)
    let later = try db.writer.write { d in
        try store.insertNudge(nudge("later", at: last.addingTimeInterval(5_400)), dailyCap: 3, minGap: 5_400,
                              dayStart: dayStart, in: d)
    }
    #expect(later?.id != nil)
    // Briefs are not nudges: they neither count toward the cap nor reset the gap.
    try db.writer.write { d in
        _ = try store.insertIfNew(.fixture(kind: .eveningWrap, key: "evening", at: last.addingTimeInterval(6_000)), in: d)
    }
    #expect(try store.nudgeCount(since: dayStart) == 2)
    #expect(try store.lastNudgeAt() == last.addingTimeInterval(5_400))
}

@Test func nudgeWithAnExistingKeyIsNotInsertedTwice() throws {
    let db = try AppDatabase.inMemory()
    let store = InboxStore(db)
    let insert = {
        try db.writer.write { d in
            try store.insertNudge(nudge("flag:1", at: assistantT0), dailyCap: 3, minGap: 0, dayStart: assistantT0, in: d)
        }
    }
    #expect(try insert() != nil)
    #expect(try insert() == nil)
    #expect(try store.nudgeCount(since: assistantT0) == 1)
}

@Test func unseenCountMarkSeenAndNotified() throws {
    let db = try AppDatabase.inMemory()
    let store = InboxStore(db)
    let (a, b) = try db.writer.write { d in
        (try store.insertIfNew(.fixture(key: "a"), in: d)!, try store.insertIfNew(.fixture(key: "b"), in: d)!)
    }
    #expect(try store.unseenCount() == 2)
    let seenAt = assistantT0.addingTimeInterval(60)
    try store.markSeen([a.id!], at: seenAt)
    #expect(try store.unseenCount() == 1)
    // Marking again keeps the first time it was seen.
    try store.markSeen([a.id!, b.id!], at: seenAt.addingTimeInterval(60))
    #expect(try store.unseenCount() == 0)
    let rows = try db.reader.read { try InboxMessage.order(Column("id")).fetchAll($0) }
    #expect(rows.map(\.seenAt) == [seenAt, seenAt.addingTimeInterval(60)])
    #expect(rows.allSatisfy { !$0.notified })
    try store.setNotified(b.id!)
    let notified = try db.reader.read { try InboxMessage.order(Column("id")).fetchAll($0) }.map(\.notified)
    #expect(notified == [false, true])
    try store.markSeen([], at: seenAt)  // no-op
}

@Test func nudgeDecisionUpsertsAndCascadesWithFlag() throws {
    let db = try AppDatabase.inMemory()
    let store = NudgeDecisionStore(db)
    let flag = try db.writer.write { d in
        var f = SalientFlag(kind: .commitment, text: "reply to Ada", owner: .user, dedupeKey: "c|1",
                            createdAt: assistantT0, lastSeenAt: assistantT0)
        try f.insert(d)
        return f
    }
    #expect(try store.decision(flagID: flag.id!) == nil)
    let declined = NudgeDecision(flagID: flag.id!, decision: .declined, flagLastSeenAt: assistantT0,
                                 decidedAt: assistantT0)
    try db.writer.write { try store.record(declined, in: $0) }
    #expect(try store.decision(flagID: flag.id!) == declined)
    let sent = NudgeDecision(flagID: flag.id!, decision: .sent, flagLastSeenAt: assistantT0.addingTimeInterval(90_000),
                             decidedAt: assistantT0.addingTimeInterval(90_000))
    try db.writer.write { try store.record(sent, in: $0) }
    #expect(try store.decision(flagID: flag.id!) == sent)
    #expect(try rowCount(db, "nudge_decisions") == 1)
    #expect(try db.reader.read { try store.decision(flagID: flag.id!, in: $0) } == sent)
    try db.writer.write { d in _ = try SalientFlag.deleteAll(d) }
    #expect(try store.decision(flagID: flag.id!) == nil)
}

@Test func insertNudgeRefusesOtherKinds() throws {
    let db = try AppDatabase.inMemory()
    let store = InboxStore(db)
    let row = try db.writer.write { d in
        try store.insertNudge(.fixture(kind: .morningBrief, key: "m"), dailyCap: 3, minGap: 0, dayStart: assistantT0, in: d)
    }
    #expect(row == nil)
    #expect(try rowCount(db, "inbox_messages") == 0)
}
