import Foundation
import GRDB

// Plan 5 (chat + proactive) records over the `v5` tables. JSON columns (`tools`,
// `llm_call_ids`) are TEXT holding JSON, encoded by GRDB from the Codable values. Every text
// here is user or model text: never log it. Callers redact model output before storing it.

// MARK: - Enums (raw values = the CHECK values)

public enum ReminderAction: String, Codable, Sendable, CaseIterable { case notify, prompt }
public enum ReminderKind: String, Codable, Sendable, CaseIterable { case once, recurring, interval }
public enum ReminderStatus: String, Codable, Sendable, CaseIterable { case active, done, cancelled }
/// Who created a reminder (`reminders.created_by`).
public enum ReminderOrigin: String, Codable, Sendable, CaseIterable { case user, chat }
public enum InboxKind: String, Codable, Sendable, CaseIterable {
    case morningBrief = "morning_brief"
    case eveningWrap = "evening_wrap"
    case nudge, reminder
}
public enum ChatRole: String, Codable, Sendable, CaseIterable { case user, assistant }
public enum ChatTurnStatus: String, Codable, Sendable, CaseIterable { case pending, complete, cancelled, failed }
public enum NudgeVerdict: String, Codable, Sendable, CaseIterable { case sent, declined, unverified }

// MARK: - reminders

public struct Reminder: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var text: String
    public var action: ReminderAction
    public var kind: ReminderKind
    /// The first occurrence (once: the fire time; recurring: DTSTART; interval: the origin).
    public var anchorAt: Date
    /// RFC 5545 RRULE body for `.recurring`.
    public var rrule: String?
    /// The period of an `.interval` reminder.
    public var intervalSeconds: Int?
    /// The time zone identifier the reminder was created in.
    public var timeZone: String
    /// nil once the reminder will never fire again.
    public var nextFireAt: Date?
    public var fireCount: Int
    public var lastFiredAt: Date?
    public var status: ReminderStatus
    public var createdBy: ReminderOrigin
    public var createdAt: Date

    public init(id: Int64? = nil, text: String, action: ReminderAction, kind: ReminderKind, anchorAt: Date,
                rrule: String? = nil, intervalSeconds: Int? = nil, timeZone: String, nextFireAt: Date? = nil,
                fireCount: Int = 0, lastFiredAt: Date? = nil, status: ReminderStatus = .active,
                createdBy: ReminderOrigin, createdAt: Date) {
        self.id = id; self.text = text; self.action = action; self.kind = kind; self.anchorAt = anchorAt
        self.rrule = rrule; self.intervalSeconds = intervalSeconds; self.timeZone = timeZone
        self.nextFireAt = nextFireAt; self.fireCount = fireCount; self.lastFiredAt = lastFiredAt
        self.status = status; self.createdBy = createdBy; self.createdAt = createdAt
    }

    public static let databaseTableName = "reminders"

    enum CodingKeys: String, CodingKey {
        case id, text, action, kind, rrule, status
        case anchorAt = "anchor_at"
        case intervalSeconds = "interval_seconds"
        case timeZone = "time_zone"
        case nextFireAt = "next_fire_at"
        case fireCount = "fire_count"
        case lastFiredAt = "last_fired_at"
        case createdBy = "created_by"
        case createdAt = "created_at"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

// MARK: - inbox_messages

/// A proactive message (brief, wrap, nudge, reminder) delivered to the chat.
public struct InboxMessage: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var kind: InboxKind
    public var title: String
    public var body: String
    /// Unique: a brief per day (`morning:2026-11-20`), a nudge per flag, a reminder per firing.
    public var dedupeKey: String
    public var createdAt: Date
    public var seenAt: Date?
    /// A macOS notification was posted for it.
    public var notified: Bool
    public var reminderID: Int64?
    public var flagID: Int64?
    public var llmCallIDs: [Int64]

    public init(id: Int64? = nil, kind: InboxKind, title: String, body: String, dedupeKey: String, createdAt: Date,
                seenAt: Date? = nil, notified: Bool = false, reminderID: Int64? = nil, flagID: Int64? = nil,
                llmCallIDs: [Int64] = []) {
        self.id = id; self.kind = kind; self.title = title; self.body = body; self.dedupeKey = dedupeKey
        self.createdAt = createdAt; self.seenAt = seenAt; self.notified = notified; self.reminderID = reminderID
        self.flagID = flagID; self.llmCallIDs = llmCallIDs
    }

    public static let databaseTableName = "inbox_messages"

    public var isRoutineFinding: Bool { kind == .nudge && dedupeKey.hasPrefix(RoutineFindings.inboxKeyPrefix) }

    enum CodingKeys: String, CodingKey {
        case id, kind, title, body, notified
        case dedupeKey = "dedupe_key"
        case createdAt = "created_at"
        case seenAt = "seen_at"
        case reminderID = "reminder_id"
        case flagID = "flag_id"
        case llmCallIDs = "llm_call_ids"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

// MARK: - chat_turns

/// One tool call made during an assistant turn, as shown under the message. `receipt` is the
/// user-facing receipt of an action (never a raw tool output).
public struct ToolTrace: Codable, Sendable, Equatable {
    public var name: String
    public var ok: Bool
    /// Whether the user confirmed the action (nil when no confirmation was needed).
    public var confirmed: Bool?
    public var receipt: String?

    public init(name: String, ok: Bool, confirmed: Bool? = nil, receipt: String? = nil) {
        self.name = name; self.ok = ok; self.confirmed = confirmed; self.receipt = receipt
    }
}

public struct ChatTurn: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var createdAt: Date
    public var role: ChatRole
    public var text: String
    public var status: ChatTurnStatus
    /// A stable error code (`LLMError.errorCode`, "interrupted", "unavailable"), never content.
    public var error: String?
    public var tools: [ToolTrace]
    public var llmCallIDs: [Int64]
    /// The inbox message this assistant turn delivers (briefs, nudges, reminders).
    public var inboxID: Int64?
    /// Covered by a `chat_summaries` row; no longer replayed to the model.
    public var folded: Bool
    /// The turn's prompt or tools carried captured or derived text (untrusted). A later turn that
    /// replays it starts tainted, so its actions ask first.
    public var tainted: Bool
    /// The reply used a saved note directly or through a prior reply. This survives chat retention
    /// pruning the turn that originally searched the notes.
    public var usedSavedNotes: Bool

    public init(id: Int64? = nil, createdAt: Date, role: ChatRole, text: String, status: ChatTurnStatus,
                error: String? = nil, tools: [ToolTrace] = [], llmCallIDs: [Int64] = [], inboxID: Int64? = nil,
                folded: Bool = false, tainted: Bool = false, usedSavedNotes: Bool = false) {
        self.id = id; self.createdAt = createdAt; self.role = role; self.text = text; self.status = status
        self.error = error; self.tools = tools; self.llmCallIDs = llmCallIDs; self.inboxID = inboxID
        self.folded = folded; self.tainted = tainted; self.usedSavedNotes = usedSavedNotes
    }

    public static let databaseTableName = "chat_turns"

    enum CodingKeys: String, CodingKey {
        case id, role, text, status, error, tools, folded, tainted
        case createdAt = "created_at"
        case llmCallIDs = "llm_call_ids"
        case inboxID = "inbox_id"
        case usedSavedNotes = "used_saved_notes"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

// MARK: - chat_summaries

/// The folded history: a summary of every turn with `id <= throughTurnID`.
public struct ChatSummary: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var throughTurnID: Int64
    public var body: String
    public var createdAt: Date
    public var llmCallID: Int64?

    public init(id: Int64? = nil, throughTurnID: Int64, body: String, createdAt: Date, llmCallID: Int64? = nil) {
        self.id = id; self.throughTurnID = throughTurnID; self.body = body; self.createdAt = createdAt
        self.llmCallID = llmCallID
    }

    public static let databaseTableName = "chat_summaries"

    enum CodingKeys: String, CodingKey {
        case id, body
        case throughTurnID = "through_turn_id"
        case createdAt = "created_at"
        case llmCallID = "llm_call_id"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

// MARK: - nudge_decisions

/// The last nudge verdict for a salient flag (one row per flag; cascades with it).
public struct NudgeDecision: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    public var flagID: Int64
    public var decision: NudgeVerdict
    /// The flag's `last_seen_at` when decided: a declined flag is re-triaged only once seen again later.
    public var flagLastSeenAt: Date
    public var decidedAt: Date
    public var llmCallID: Int64?

    public init(flagID: Int64, decision: NudgeVerdict, flagLastSeenAt: Date, decidedAt: Date, llmCallID: Int64? = nil) {
        self.flagID = flagID; self.decision = decision; self.flagLastSeenAt = flagLastSeenAt
        self.decidedAt = decidedAt; self.llmCallID = llmCallID
    }

    public static let databaseTableName = "nudge_decisions"

    enum CodingKeys: String, CodingKey {
        case decision
        case flagID = "flag_id"
        case flagLastSeenAt = "flag_last_seen_at"
        case decidedAt = "decided_at"
        case llmCallID = "llm_call_id"
    }
}
