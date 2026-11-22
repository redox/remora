import Foundation
import GRDB
import Testing
@testable import Storage

@Test func v5MigratesV4Database() throws {
    let url = tempDir().appending(path: "remora.sqlite")
    let queue = try DatabaseQueue(path: url.path)
    try Migrations.make().migrate(queue, upTo: "v4")
    try queue.write { d in
        var flag = SalientFlag(kind: .todo, text: "send the deck", owner: .user, dedupeKey: "todo|pre-v5",
                               createdAt: memoryT0, lastSeenAt: memoryT0)
        try flag.insert(d)
    }
    try queue.close()

    let db = try AppDatabase.open(at: url)
    let (tables, indexes, migrations): ([String], [String], [String]) = try db.reader.read { d in
        (try String.fetchAll(d, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"),
         try String.fetchAll(d, sql: "SELECT name FROM sqlite_master WHERE type = 'index'"),
         try String.fetchAll(d, sql: "SELECT identifier FROM grdb_migrations"))
    }
    let flags = try db.reader.read { try SalientFlag.fetchAll($0) }
    #expect(flags.map(\.dedupeKey) == ["todo|pre-v5"])
    for t in assistantTables { #expect(tables.contains(t), "missing table \(t)") }
    for i in ["reminders_on_status_next_fire_at", "inbox_messages_on_created_at", "chat_turns_on_created_at"] {
        #expect(indexes.contains(i), "missing index \(i)")
    }
    #expect(migrations.contains("v5"))
    // The flag that existed before v5 can carry a nudge decision.
    try db.writer.write { d in
        var n = NudgeDecision(flagID: flags[0].id!, decision: .sent, flagLastSeenAt: memoryT0, decidedAt: memoryT0)
        try n.insert(d)
    }
    #expect(try rowCount(db, "nudge_decisions") == 1)
}

@Test func v5CheckConstraintsRejectUnknownValues() throws {
    let db = try AppDatabase.inMemory()
    let t = "'2026-11-20 08:00:00.000'"
    let bad = [
        "INSERT INTO reminders (text, action, kind, anchor_at, time_zone, created_by, created_at) VALUES ('r', 'shout', 'once', \(t), 'UTC', 'user', \(t))",
        "INSERT INTO reminders (text, action, kind, anchor_at, time_zone, created_by, created_at) VALUES ('r', 'notify', 'weekly', \(t), 'UTC', 'user', \(t))",
        "INSERT INTO reminders (text, action, kind, anchor_at, time_zone, status, created_by, created_at) VALUES ('r', 'notify', 'once', \(t), 'UTC', 'paused', 'user', \(t))",
        "INSERT INTO reminders (text, action, kind, anchor_at, time_zone, created_by, created_at) VALUES ('r', 'notify', 'once', \(t), 'UTC', 'mcp', \(t))",
        "INSERT INTO inbox_messages (kind, title, body, dedupe_key, created_at) VALUES ('digest', 't', 'b', 'k', \(t))",
        "INSERT INTO chat_turns (created_at, role, text, status) VALUES (\(t), 'system', 'x', 'complete')",
        "INSERT INTO chat_turns (created_at, role, text, status) VALUES (\(t), 'user', 'x', 'streaming')",
        "INSERT INTO nudge_decisions (flag_id, decision, flag_last_seen_at, decided_at) VALUES (1, 'maybe', \(t), \(t))",
    ]
    for sql in bad {
        #expect(throws: DatabaseError.self, "\(sql)") { try db.writer.write { try $0.execute(sql: sql) } }
    }
    // The defaults the brief pins.
    try db.writer.write { d in
        try d.execute(sql: "INSERT INTO reminders (text, action, kind, anchor_at, time_zone, created_by, created_at) VALUES ('r', 'notify', 'once', \(t), 'UTC', 'chat', \(t))")
        try d.execute(sql: "INSERT INTO inbox_messages (kind, title, body, dedupe_key, created_at) VALUES ('nudge', 't', 'b', 'k', \(t))")
        try d.execute(sql: "INSERT INTO chat_turns (created_at, role, text, status) VALUES (\(t), 'user', 'x', 'pending')")
    }
    let r = try #require(try db.reader.read { try Reminder.fetchOne($0) })
    #expect(r.status == .active && r.fireCount == 0 && r.createdBy == .chat)
    let m = try #require(try db.reader.read { try InboxMessage.fetchOne($0) })
    #expect(!m.notified && m.llmCallIDs == [] && m.seenAt == nil)
    let c = try #require(try db.reader.read { try ChatTurn.fetchOne($0) })
    #expect(!c.folded && !c.tainted && c.tools == [] && c.llmCallIDs == [])
}

@Test func v5ForeignKeysNullOrCascade() throws {
    let db = try AppDatabase.inMemory()
    let flag = try seedAssistantRows(db)
    // Deleting the reminder, flag and llm call nulls the references; the decision cascades with the flag.
    try db.writer.write { d in
        _ = try Reminder.deleteAll(d)
        _ = try SalientFlag.deleteOne(d, key: flag.id)
        _ = try LLMCall.deleteAll(d)
    }
    let m = try #require(try db.reader.read { try InboxMessage.fetchOne($0) })
    #expect(m.reminderID == nil && m.flagID == nil)
    #expect(try rowCount(db, "nudge_decisions") == 0)
    try db.writer.write { d in _ = try InboxMessage.deleteAll(d) }
    let turn = try #require(try db.reader.read { try ChatTurn.fetchOne($0) })
    #expect(turn.inboxID == nil)
    // A nudge decision cannot cite a missing flag.
    #expect(throws: DatabaseError.self) {
        try db.writer.write { d in
            var n = NudgeDecision(flagID: 999, decision: .sent, flagLastSeenAt: memoryT0, decidedAt: memoryT0)
            try n.insert(d)
        }
    }
}

@Test func assistantRecordsRoundTripJSONColumns() throws {
    let db = try AppDatabase.inMemory()
    var turn = ChatTurn.fixture(role: .assistant, text: "done", status: .failed)
    turn.error = "unavailable"
    turn.tools = [ToolTrace(name: "pause_capture", ok: true, confirmed: true, receipt: "Paused for 1 hour"),
                  ToolTrace(name: "search_memory", ok: false, confirmed: nil, receipt: nil)]
    turn.llmCallIDs = [4, 2]
    var reminder = Reminder(text: "standup", action: .prompt, kind: .recurring, anchorAt: assistantT0,
                            rrule: "FREQ=DAILY", timeZone: "Europe/Paris", nextFireAt: assistantT0,
                            createdBy: .chat, createdAt: assistantT0)
    try db.writer.write { d in try turn.insert(d); try reminder.insert(d) }
    let (t2, r2) = try db.reader.read { d in
        (try ChatTurn.fetchOne(d, key: turn.id), try Reminder.fetchOne(d, key: reminder.id))
    }
    #expect(t2 == turn)
    #expect(r2 == reminder)
    let raw: String? = try db.reader.read { try String.fetchOne($0, sql: "SELECT llm_call_ids FROM chat_turns") }
    #expect(raw == "[4,2]")
    #expect(ReminderAction.allCases.map(\.rawValue) == ["notify", "prompt"])
    #expect(ReminderKind.allCases.map(\.rawValue) == ["once", "recurring", "interval"])
    #expect(ReminderStatus.allCases.map(\.rawValue) == ["active", "done", "cancelled"])
    #expect(ReminderOrigin.allCases.map(\.rawValue) == ["user", "chat"])
    #expect(InboxKind.allCases.map(\.rawValue) == ["morning_brief", "evening_wrap", "nudge", "reminder"])
    #expect(ChatRole.allCases.map(\.rawValue) == ["user", "assistant"])
    #expect(ChatTurnStatus.allCases.map(\.rawValue) == ["pending", "complete", "cancelled", "failed"])
    #expect(NudgeVerdict.allCases.map(\.rawValue) == ["sent", "declined", "unverified"])
}

/// Deferred parity (B.27): every table the migrations create is either wiped by delete-all or
/// deliberately kept. A new table must be classified here (and in `DataReset`).
@Test func everyTableIsWipedOrDeliberatelyKept() throws {
    let db = try AppDatabase.inMemory()
    var tables: Set<String> = try db.reader.read { d in
        Set(try String.fetchAll(d, sql: """
            SELECT name FROM sqlite_master WHERE type = 'table'
              AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' AND name NOT LIKE 'grdb\\_%' ESCAPE '\\'
            """))
    }
    // FTS5 virtual tables and their shadow tables (`<name>_data`, `_idx`, `_docsize`, `_config`, `_content`).
    let ftsNames = ["snapshots_fts", "chronicle_fts", "wiki_pages_fts", "wiki_facts_fts", "imported_meetings_fts",
                    "saved_notes_fts"]
    let ftsShadows = ["", "_data", "_idx", "_docsize", "_config", "_content"]
    tables.subtract(ftsNames.flatMap { n in ftsShadows.map { n + $0 } })
    let capture: Set<String> = ["snapshots", "activity_events", "inline_outputs", "style_notes",
                                "imported_meetings", "forgotten_imports", "saved_notes"]
    let kept: Set<String> = ["settings", "exclusions", "llm_calls", "time_rules" /* user rules kept */]
    let wiped = capture.union(DataReset.derivedMemoryTables).union(DataReset.assistantTables)
    #expect(Set(DataReset.assistantTables) == Set(assistantTables))
    #expect(wiped.union(kept) == tables)
    #expect(wiped.isDisjoint(with: kept))
    // FTS indexes: every one is emptied by delete-all.
    let fts: Set<String> = try db.reader.read { d in
        Set(try String.fetchAll(d, sql: "SELECT name FROM sqlite_master WHERE sql LIKE 'CREATE VIRTUAL TABLE%'"))
    }
    #expect(fts == Set(ftsNames))
}
