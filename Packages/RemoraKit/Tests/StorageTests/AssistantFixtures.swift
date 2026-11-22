import Foundation
import GRDB
@testable import Storage

// Plan 5 (chat + proactive) fixtures over the `v5` tables.

let assistantT0 = Date(timeIntervalSince1970: 1_795_000_000)

extension ChatTurn {
    static func fixture(role: ChatRole = .user, text: String = "hello", status: ChatTurnStatus = .complete,
                        at: Date = assistantT0) -> ChatTurn {
        ChatTurn(createdAt: at, role: role, text: text, status: status)
    }
}

extension InboxMessage {
    static func fixture(kind: InboxKind = .morningBrief, key: String = "morning:2026-11-20", body: String = "body",
                        at: Date = assistantT0) -> InboxMessage {
        InboxMessage(kind: kind, title: "title", body: body, dedupeKey: key, createdAt: at)
    }
}

extension Reminder {
    static func fixture(text: String = "stretch", nextFireAt: Date? = assistantT0, status: ReminderStatus = .active,
                        at: Date = assistantT0) -> Reminder {
        Reminder(text: text, action: .notify, kind: .once, anchorAt: nextFireAt ?? at, timeZone: "Europe/Paris",
                 nextFireAt: nextFireAt, status: status, createdBy: .user, createdAt: at)
    }
}

/// One row in every v5 table, each holding `marker`; returns the flag the nudge decision cites.
@discardableResult
func seedAssistantRows(_ db: AppDatabase, marker: String = "chatmarker") throws -> SalientFlag {
    let call = try LLMCallStore(db).insert(.fixture(job: "chat"))
    return try db.writer.write { d in
        var flag = SalientFlag(kind: .todo, text: "flag \(marker)", owner: .user, dedupeKey: "todo:v5:\(marker)",
                               createdAt: assistantT0, lastSeenAt: assistantT0)
        try flag.insert(d)
        var reminder = Reminder.fixture(text: "reminder \(marker)")
        try reminder.insert(d)
        var inbox = InboxMessage.fixture(key: "k:\(marker)", body: "inbox \(marker)")
        inbox.reminderID = reminder.id
        inbox.flagID = flag.id
        inbox.llmCallIDs = [call.id!]
        try inbox.insert(d)
        var turn = ChatTurn.fixture(role: .assistant, text: "turn \(marker)")
        turn.inboxID = inbox.id
        turn.tools = [ToolTrace(name: "search_memory", ok: true, confirmed: nil, receipt: "receipt \(marker)")]
        try turn.insert(d)
        var summary = ChatSummary(throughTurnID: turn.id!, body: "summary \(marker)", createdAt: assistantT0,
                                  llmCallID: call.id)
        try summary.insert(d)
        var decision = NudgeDecision(flagID: flag.id!, decision: .declined, flagLastSeenAt: assistantT0,
                                     decidedAt: assistantT0, llmCallID: call.id)
        try decision.insert(d)
        return flag
    }
}

/// The v5 tables delete-all empties.
let assistantTables = ["chat_turns", "chat_summaries", "inbox_messages", "nudge_decisions", "reminders"]

func rowCount(_ db: AppDatabase, _ table: String) throws -> Int {
    try db.reader.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM \(table)") ?? -1 }
}
