import Foundation
import GRDB
import LLM
import Memory
import Redaction
import Storage
import Synchronization
import os

/// Runs a `prompt` reminder: Task 5's `ChatAgent.answer(prompt:job:)` (read-only tools, no history,
/// no persistence) conforms.
public protocol ReminderAnswering: Sendable {
    func answer(prompt: String, job: JobType) async throws -> (text: String, callIDs: [Int64])
}

/// A `prompt` firing committed by `fireDue` whose answer is not delivered yet (setting
/// `reminders.pendingPrompts`; ids and dates only, no text).
struct PendingPrompt: Codable, Sendable, Equatable {
    var reminderID: Int64
    var scheduledFor: Date
    var firedAt: Date
}

/// Whether a `prompt` reminder may call the model now. Prompt reminders are background usage:
/// they stay under Plan 4's daily budget and its usage-limit backoff.
public enum ReminderPromptGate: Sendable, Equatable {
    case allow
    /// The daily background budget is spent (`BudgetLevel.exhausted`, or unreadable: fail closed).
    case budget
    /// A usage limit was hit and the backoff has not elapsed.
    case backoff

    /// The background jobs' own rules: `BudgetGate` and `MemorySettings.backoff`.
    public static func current(db: AppDatabase, calendar: Calendar, now: Date) -> ReminderPromptGate {
        let level = (try? BudgetGate(db: db, calendar: calendar).level(now: now)) ?? .exhausted
        if level == .exhausted { return .budget }
        if !MemorySettings(SettingsStore(db)).backoff().allowsProbe(at: now) { return .backoff }
        return .allow
    }
}

/// Fires due reminders and delivers each firing to the chat inbox.
///
/// `ReminderEngine.fireDue` is at-most-once: it commits the firing before anything else. So:
/// - a `notify` reminder's inbox row and chat turn are inserted **inside** `fireDue`'s transaction
///   (no model call to wait for): fired and delivered commit together, or neither;
/// - a `prompt` firing is recorded in `reminders.pendingPrompts` in that same transaction. Its answer
///   is delivered afterwards through `DataGeneration.write(expected:)` with the generation read
///   **before** firing, re-checking that the reminder row still exists (a delete-all or a removed
///   reminder delivers nothing), and the record is then removed. A crash in between leaves the
///   record: the next `fire()` starts with a recovery sweep that re-delivers records of the last
///   24 h whose inbox row is missing. The dedupe key `reminder:<id>:<scheduledFor unix>` keeps every
///   path idempotent.
/// Reminder texts and answers are user and model text: never logged.
public struct ReminderDispatcher: Sendable {
    public static let title = "Reminder"
    static let pendingKey = "reminders.pendingPrompts"
    /// Older undelivered prompt firings are dropped, not re-run.
    static let recoveryWindow: TimeInterval = 24 * 3_600

    private let engine: ReminderEngine
    private let inbox: ProactiveInbox
    private let agent: (any ReminderAnswering)?
    private let calendar: @Sendable () -> Calendar
    private let now: @Sendable () -> Date
    private let promptGate: @Sendable (Date) -> ReminderPromptGate
    private let redactor = Redactor()
    private static let log = Logger(subsystem: "dev.remora", category: "reminders")

    /// `promptGate` (default `ReminderPromptGate.current`) is consulted before each prompt
    /// reminder's model call.
    public init(engine: ReminderEngine, inbox: ProactiveInbox, agent: (any ReminderAnswering)?,
                calendar: @escaping @Sendable () -> Calendar = { PeriodKey.localCalendar },
                now: @escaping @Sendable () -> Date = Date.init,
                promptGate: (@Sendable (Date) -> ReminderPromptGate)? = nil) {
        self.engine = engine; self.inbox = inbox; self.agent = agent; self.calendar = calendar; self.now = now
        let db = inbox.database
        self.promptGate = promptGate ?? { at in ReminderPromptGate.current(db: db, calendar: calendar(), now: at) }
    }

    private var db: AppDatabase { inbox.database }

    /// Recovers undelivered prompt firings, fires every due reminder, and returns the messages
    /// delivered (recovered first, then in firing order).
    public func fire() async -> [InboxMessage] {
        var delivered = await recover()
        let committed: (generation: Int, firings: [Firing], notified: [InboxMessage])
        do {
            committed = try await commitFirings()
        } catch {
            Self.log.error("fire failed: \(Self.code(error), privacy: .public)")
            return delivered
        }
        for m in committed.notified {
            await inbox.delivered(m)
            delivered.append(m)
        }
        for firing in committed.firings where firing.reminder.action == .prompt {
            do {
                if let m = try await deliver(firing, generation: committed.generation) { delivered.append(m) }
                try removePending([pending(firing)])
            } catch is DataGeneration.Stale {
                // The reminders are gone; the sweep drops their records.
                Self.log.info("reminders discarded after delete-all")
                break
            } catch {
                Self.log.error("reminder delivery failed: \(Self.code(error), privacy: .public)")
            }
        }
        Self.log.info("reminders fired \(committed.firings.count, privacy: .public), delivered \(delivered.count, privacy: .public)")
        return delivered
    }

    /// Reads the generation, then fires in one transaction that also stores each `notify`
    /// firing's message and records each `prompt` firing as pending. The caller announces the
    /// notified messages (`inbox.delivered`) after this returns.
    func commitFirings() async throws -> (generation: Int, firings: [Firing], notified: [InboxMessage]) {
        let generation = try inbox.generation()
        let notified = Collected()
        let inbox = inbox, calendar = calendar, at = now()
        let firings = try await engine.fireDue { f, d in
            guard let id = f.reminder.id else { return }
            switch f.reminder.action {
            case .notify:
                if let m = try inbox.insert(kind: .reminder, title: Self.title, body: Self.notifyBody(f, calendar: calendar()),
                                            dedupeKey: Self.dedupeKey(f), callIDs: [], reminderID: id, at: at, in: d) {
                    notified.append(m)
                }
            case .prompt:
                let settings = SettingsStore(inbox.database)
                var list = try settings.value([PendingPrompt].self, forKey: Self.pendingKey, in: d) ?? []
                list.append(PendingPrompt(reminderID: id, scheduledFor: f.scheduledFor, firedAt: at))
                try settings.setValue(list, forKey: Self.pendingKey, in: d)
            }
        }
        return (generation, firings, notified.all)
    }

    /// Re-delivers prompt firings recorded in the last 24 h whose message is missing (a crash
    /// between firing and delivery); drops older records and those already delivered or whose
    /// reminder is gone or cancelled. An unreadable list is logged (code only) and dropped.
    func recover() async -> [InboxMessage] {
        let list: [PendingPrompt]
        do { list = try SettingsStore(db).value([PendingPrompt].self, forKey: Self.pendingKey) ?? [] } catch {
            Self.log.error("pending reminders unreadable: \(Self.code(error), privacy: .public)")
            try? SettingsStore(db).setValue([PendingPrompt]?.none, forKey: Self.pendingKey)   // fail safe: drop
            return []
        }
        guard !list.isEmpty else { return [] }
        let t = now()
        var done: [PendingPrompt] = [], delivered: [InboxMessage] = []
        let store = ReminderStore(db)
        do {
            let generation = try inbox.generation()
            for p in list {
                let key = Self.dedupeKey(reminderID: p.reminderID, scheduledFor: p.scheduledFor)
                let alreadyDelivered = try inbox.delivered(dedupeKey: key)
                if p.firedAt < t.addingTimeInterval(-Self.recoveryWindow) || alreadyDelivered {
                    done.append(p); continue
                }
                // Gone, or cancelled since it fired: dropped. A fired one-time reminder is already
                // `done`, so `done` is still re-delivered.
                guard let reminder = try store.get(p.reminderID), reminder.status != .cancelled else {
                    done.append(p); continue
                }
                let firing = Firing(reminder: reminder, scheduledFor: p.scheduledFor, late: false)
                if let m = try await deliver(firing, generation: generation) { delivered.append(m) }
                done.append(p)
            }
        } catch {
            Self.log.error("reminder recovery stopped: \(Self.code(error), privacy: .public)")
        }
        try? removePending(done)
        if !delivered.isEmpty { Self.log.info("recovered \(delivered.count, privacy: .public) reminders") }
        return delivered
    }

    /// Builds the body (running the agent for a `prompt` reminder) and delivers it. nil: a duplicate
    /// or a reminder gone meanwhile. Throws `DataGeneration.Stale` after a delete-all.
    func deliver(_ f: Firing, generation: Int) async throws -> InboxMessage? {
        guard let id = f.reminder.id else { return nil }
        let body: String
        var callIDs: [Int64] = []
        switch f.reminder.action {
        case .notify:
            body = Self.notifyBody(f, calendar: calendar())
        case .prompt:
            (body, callIDs) = await promptAnswer(f.reminder.text)
        }
        return try await inbox.deliver(kind: .reminder, title: Self.title, body: body, dedupeKey: Self.dedupeKey(f),
                                       callIDs: callIDs, reminderID: id, expectedGeneration: generation, at: now())
    }

    /// The prompt's answer, or the "Couldn't run" copy: the budget and the backoff are checked
    /// before any model call.
    private func promptAnswer(_ text: String) async -> (body: String, callIDs: [Int64]) {
        switch promptGate(now()) {
        case .budget:
            return ("Couldn't run “\(text)”: \(Self.budgetCopy)", [])
        case .backoff:
            return ("Couldn't run “\(text)”: \(Self.copy(for: LLMError.usageLimit))", [])
        case .allow:
            do {
                guard let agent else { throw LLMError.configuration(code: "no_agent") }
                let answer = try await agent.answer(prompt: text, job: .reminderPrompt)
                return (redactor.redact(answer.text.trimmingCharacters(in: .whitespacesAndNewlines)),
                        answer.callIDs.filter { $0 > 0 })
            } catch {
                return ("Couldn't run “\(text)”: \(Self.copy(for: error))", [])
            }
        }
    }

    private func pending(_ f: Firing) -> PendingPrompt {
        PendingPrompt(reminderID: f.reminder.id ?? 0, scheduledFor: f.scheduledFor, firedAt: .distantPast)
    }

    /// Removes the records matching (reminder, scheduled time), in one write.
    private func removePending(_ entries: [PendingPrompt]) throws {
        guard !entries.isEmpty else { return }
        let settings = SettingsStore(db)
        try db.writer.write { d in
            let list = try settings.value([PendingPrompt].self, forKey: Self.pendingKey, in: d) ?? []
            let left = list.filter { p in
                !entries.contains { $0.reminderID == p.reminderID && $0.scheduledFor == p.scheduledFor }
            }
            try settings.setValue(left.isEmpty ? nil : left, forKey: Self.pendingKey, in: d)
        }
    }

    static func notifyBody(_ f: Firing, calendar: Calendar) -> String {
        var body = f.reminder.text
        if f.late { body += "\n\n_Due at \(ProactivePrompt.stamp(f.scheduledFor, calendar: calendar, format: "HH:mm"))._" }
        return body
    }

    static func dedupeKey(_ f: Firing) -> String {
        dedupeKey(reminderID: f.reminder.id ?? 0, scheduledFor: f.scheduledFor)
    }

    static func dedupeKey(reminderID: Int64, scheduledFor: Date) -> String {
        "reminder:\(reminderID):\(Int(scheduledFor.timeIntervalSince1970))"
    }

    /// A loggable code, never a description (F-60).
    static func code(_ error: any Error) -> String {
        if let e = error as? LLMError { return e.errorCode ?? "llm" }
        if let e = error as? any CodedError { return e.code }
        return String(describing: type(of: error))
    }

    static let budgetCopy = "daily background budget reached"

    /// User copy for a failed prompt reminder.
    static func copy(for error: any Error) -> String {
        switch error as? LLMError {
        case .usageLimit?: "usage limit reached"
        case .notSignedIn?, .needsSignIn?, .planUsageDisabled?: "sign in to ChatGPT"
        default: "ChatGPT unavailable"
        }
    }
}

/// Messages stored inside `fireDue`'s transaction, announced after its commit.
private final class Collected: Sendable {
    private let items = Mutex<[InboxMessage]>([])
    func append(_ m: InboxMessage) { items.withLock { $0.append(m) } }
    var all: [InboxMessage] { items.withLock { $0 } }
}
