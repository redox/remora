import Foundation
import GRDB

/// The chat history (`chat_turns`) and its folded summaries (`chat_summaries`).
///
/// Writes that a caller runs inside its own transaction (inbox delivery) take `in d: Database`
/// (GRDB writes are not reentrant). Turn texts are user or model text: never log them.
public struct ChatStore: Sendable {
    private let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    /// The error code a turn left `pending` by a quit or crash gets at the next launch.
    public static let interruptedError = "interrupted"

    public enum EditError: Error { case unavailable }

    /// Removes the latest question and its reply before inserting an edited replacement in the
    /// same transaction. Completed actions remain as receipts: editing cannot undo side effects.
    /// Callers must finish any running turn and history fold before entering this transaction.
    public func prepareForResend(userTurnID: Int64, in d: Database) throws {
        guard let user = try ChatTurn.fetchOne(d, sql: "SELECT * FROM chat_turns WHERE role = 'user' ORDER BY id DESC LIMIT 1"),
              user.id == userTurnID, user.status == .complete,
              try ChatTurn.filter(Column("status") == "pending").fetchCount(d) == 0
        else { throw EditError.unavailable }
        let replies = try ChatTurn.fetchAll(d, sql: "SELECT * FROM chat_turns WHERE id > ? AND role = 'assistant' AND inbox_id IS NULL",
                                            arguments: [userTurnID])
        for var reply in replies {
            let receipts = reply.tools.compactMap(\.receipt)
            if receipts.isEmpty {
                try reply.delete(d)
            } else {
                reply.text = "Actions already completed before editing the previous message (not undone):\n" + receipts.joined(separator: "\n")
                reply.status = .complete
                reply.error = nil
                reply.tainted = true
                try reply.update(d)
            }
        }
        try user.delete(d)
        // Summaries containing the replaced question must not leak its old wording back into
        // subsequent prompts. Earlier summaries are still valid, and stored rows can be unfolded.
        try d.execute(sql: "DELETE FROM chat_summaries WHERE through_turn_id >= ?", arguments: [userTurnID])
        let through = try latestSummary(in: d)?.throughTurnID ?? 0
        try d.execute(sql: "UPDATE chat_turns SET folded = (id <= ?)", arguments: [through])
    }

    /// Inserts `t` and returns it with its id.
    @discardableResult
    public func append(_ t: ChatTurn) throws -> ChatTurn {
        try db.writer.write { try append(t, in: $0) }
    }

    @discardableResult
    public func append(_ t: ChatTurn, in d: Database) throws -> ChatTurn {
        var row = t
        row.id = nil
        try row.insert(d)
        return row
    }

    /// Rewrites a stored turn. A turn that no longer exists (delete-all or `clear()` ran while it
    /// streamed) is left deleted: never re-inserted.
    public func update(_ t: ChatTurn) throws {
        guard t.id != nil else { return }
        try db.writer.write { d in
            do { try t.update(d) } catch RecordError.recordNotFound { return }
        }
    }

    /// Chronological (oldest first). Without a cursor, the newest `limit` turns; with one, the
    /// first `limit` turns after it.
    public func turns(after id: Int64? = nil, limit: Int) throws -> [ChatTurn] {
        guard limit > 0 else { return [] }
        return try db.reader.read { d in
            if let id {
                return try ChatTurn.fetchAll(d, sql: "SELECT * FROM chat_turns WHERE id > ? ORDER BY id LIMIT ?",
                                             arguments: [id, limit])
            }
            return try ChatTurn.fetchAll(d, sql: "SELECT * FROM chat_turns ORDER BY id DESC LIMIT ?",
                                         arguments: [limit]).reversed()
        }
    }

    /// Every turn not yet covered by a summary, oldest first.
    public func unfolded() throws -> [ChatTurn] {
        try db.reader.read { try unfolded(in: $0) }
    }

    /// `unfolded()` on an existing connection (one consistent read with the summary).
    public func unfolded(in d: Database) throws -> [ChatTurn] {
        try ChatTurn.fetchAll(d, sql: "SELECT * FROM chat_turns WHERE folded = 0 ORDER BY id")
    }

    /// What may be replayed to the model: the unfolded turns and the latest summary, minus anything
    /// created before the last capture forget (`ForgetMarks.chatForgetAt`). Those stay in the chat
    /// for the user (until Clear chat) but are never sent again. Automatic routine findings stay
    /// local, including when older chat turns are folded into a summary.
    public func replayable(in d: Database) throws -> (turns: [ChatTurn], summary: ChatSummary?) {
        let forgetAt = ForgetMarks.chatForgetAt(in: d)
        var turns = try ChatTurn.fetchAll(d, sql: """
            SELECT * FROM chat_turns WHERE folded = 0 AND NOT EXISTS (
                SELECT 1 FROM inbox_messages WHERE id = chat_turns.inbox_id AND dedupe_key GLOB ?
            ) ORDER BY id
            """, arguments: [RoutineFindings.inboxKeyPattern])
        var summary = try latestSummary(in: d)
        if let forgetAt {
            turns.removeAll { $0.createdAt < forgetAt }
            if let s = summary, s.createdAt < forgetAt { summary = nil }
        }
        return (turns, summary)
    }

    public func latestSummary() throws -> ChatSummary? {
        try db.reader.read { try latestSummary(in: $0) }
    }

    public func latestSummary(in d: Database) throws -> ChatSummary? {
        try ChatSummary.fetchOne(d, sql: "SELECT * FROM chat_summaries ORDER BY id DESC LIMIT 1")
    }

    /// In one transaction: stores the summary and marks every turn with `id <= throughTurnID` folded.
    /// A no-op when that turn no longer exists: the chat was wiped (delete-all, `clear()`, `prune`)
    /// while the summary was being written, and ids are never reused (AUTOINCREMENT).
    public func fold(throughTurnID: Int64, summary: String, llmCallID: Int64?, at: Date) throws {
        try db.writer.write { d in
            try fold(throughTurnID: throughTurnID, summary: summary, llmCallID: llmCallID, at: at, in: d)
        }
    }

    public func fold(throughTurnID: Int64, summary: String, llmCallID: Int64?, at: Date, in d: Database) throws {
        guard try ChatTurn.exists(d, key: throughTurnID) else { return }
        var s = ChatSummary(throughTurnID: throughTurnID, body: summary, createdAt: at, llmCallID: llmCallID)
        try s.insert(d)
        try d.execute(sql: "UPDATE chat_turns SET folded = 1 WHERE id <= ? AND folded = 0",
                      arguments: [throughTurnID])
    }

    /// At launch: every turn still `pending` (a quit or crash mid-answer) becomes `failed` with
    /// error "interrupted". `at` is the launch time (kept for the call site; not a cutoff).
    /// Returns how many.
    @discardableResult
    public func failPending(at: Date) throws -> Int {
        try db.writer.write { d in
            try d.execute(sql: "UPDATE chat_turns SET status = 'failed', error = ? WHERE status = 'pending'",
                          arguments: [Self.interruptedError])
            return d.changesCount
        }
    }

    /// Deletes turns, summaries and inbox messages created before `olderThan` (retention, 90 days).
    /// Returns the number of rows removed.
    @discardableResult
    public func prune(olderThan: Date) throws -> Int {
        try db.writer.write { d in
            var removed = 0
            for table in ["chat_turns", "chat_summaries", "inbox_messages"] {
                try d.execute(sql: "DELETE FROM \(table) WHERE created_at < ?", arguments: [olderThan])
                removed += d.changesCount
            }
            try RoutineFindings.pruneSeen(olderThan: olderThan, in: d)
            return removed
        }
    }

    /// "Clear chat": empties turns, summaries and the inbox (reminders, nudge decisions and the
    /// nudge log, `InboxStore.nudgeLogKey`, stay, so the nudge cap and gap survive).
    public func clear() throws {
        try db.writer.write { d in
            for table in ["chat_turns", "chat_summaries", "inbox_messages"] {
                try d.execute(sql: "DELETE FROM \(table)")
            }
        }
    }
}
