import Foundation
import GRDB
import LLM
import LLMTestSupport
import Synchronization
import Testing
@testable import Assistant
import Storage

/// Stands in for `ChatAgent.answer`: one real `LLMService` call (so `llm_calls` gets a row), or
/// an error; `before` runs first.
private final class FakeAgent: ReminderAnswering {
    let llm: LLMService
    let error: LLMError?
    let before: @Sendable () -> Void
    let seen = Mutex<[(String, JobType)]>([])

    init(llm: LLMService, error: LLMError? = nil, before: @escaping @Sendable () -> Void = {}) {
        self.llm = llm; self.error = error; self.before = before
    }

    func answer(prompt: String, job: JobType) async throws -> (text: String, callIDs: [Int64]) {
        seen.withLock { $0.append((prompt, job)) }
        before()
        if let error { throw error }
        let r = try await llm.complete(job, instructions: "read-only agent", input: [.user(prompt)])
        return (r.text, [r.callID])
    }
}

private struct Env {
    var db: AppDatabase
    var clock: LiveClock
    var engine: ReminderEngine
    var log: DeliveryLog
}

private func env(_ now: String) throws -> Env {
    let db = try AppDatabase.inMemory()
    let clock = LiveClock(local(now))
    let engine = ReminderEngine(store: ReminderStore(db), db: db, calendar: { paris }, now: { clock.now() })
    return Env(db: db, clock: clock, engine: engine, log: DeliveryLog())
}

private func dispatcher(_ e: Env, agent: (any ReminderAnswering)?) -> ReminderDispatcher {
    ReminderDispatcher(engine: e.engine, inbox: makeInbox(e.db, e.log), agent: agent, calendar: { paris },
                       now: { e.clock.now() })
}

private func answerFake(_ text: String) -> FakeLLMClient {
    FakeLLMClient(backend: .siwc) { _ in
        [.delta(text), .complete(.init(inputTokens: 10, cachedInputTokens: 0, outputTokens: 5, reasoningTokens: 0))]
    }
}

@Suite struct ReminderDispatcherTests {
    @Test func lateNotifyReminderSaysWhenDue() async throws {
        let e = try env("2026-11-20 08:00")
        let late = try await e.engine.create(ReminderDraft(text: "Call Anna", action: .notify,
                                                           schedule: .once(local("2026-11-20 09:00")), origin: .user))
        _ = try await e.engine.create(ReminderDraft(text: "Water plants", action: .notify,
                                                    schedule: .once(local("2026-11-20 09:09")), origin: .user))
        e.clock.set(local("2026-11-20 09:10"))
        let out = await dispatcher(e, agent: nil).fire()
        #expect(out.count == 2)
        let call = try #require(out.first { $0.reminderID == late.id })
        #expect(call.title == "Reminder")
        #expect(call.kind == .reminder)
        #expect(call.body == "Call Anna\n\n_Due at 09:00._")
        #expect(call.dedupeKey == "reminder:\(late.id!):\(Int(local("2026-11-20 09:00").timeIntervalSince1970))")
        // 60 s behind is on time: no suffix.
        #expect(out.first { $0.reminderID != late.id }?.body == "Water plants")
        #expect(try chatRows(e.db).map(\.inboxID) == out.map(\.id))
        #expect(e.log.all.count == 2)
    }

    @Test func promptReminderDeliversTheAgentAnswer() async throws {
        let e = try env("2026-11-20 08:00")
        let agent = FakeAgent(llm: service(answerFake("You have 2 meetings today."), db: e.db))
        let r = try await e.engine.create(ReminderDraft(text: "Summarize my day", action: .prompt,
                                                        schedule: .once(local("2026-11-20 09:00")), origin: .user))
        e.clock.set(local("2026-11-20 09:00"))
        let out = await dispatcher(e, agent: agent).fire()
        let m = try #require(out.first)
        #expect(m.body == "You have 2 meetings today.")
        #expect(m.reminderID == r.id)
        #expect(m.llmCallIDs == [1])
        #expect(agent.seen.withLock { $0.map(\.0) } == ["Summarize my day"])
        #expect(agent.seen.withLock { $0.map(\.1) } == [.reminderPrompt])
        #expect(try jobTypes(e.db) == ["reminder_prompt"])
        let table = try await e.db.reader.read { d in try String.fetchOne(d, sql: "SELECT artifact_table FROM llm_calls WHERE id = 1") }
        let artifactID = try await e.db.reader.read { d in try Int64.fetchOne(d, sql: "SELECT artifact_id FROM llm_calls WHERE id = 1") }
        #expect(table == "inbox_messages")
        #expect(artifactID == m.id)
        #expect(try chatRows(e.db).first?.llmCallIDs == [1])
        #expect(try SettingsStore(e.db).value([PendingPrompt].self, forKey: ReminderDispatcher.pendingKey) == nil)
    }

    @Test func promptReminderErrorsSayWhy() async throws {
        let cases: [(LLMError?, String)] = [
            (.usageLimit, "usage limit reached"), (.needsSignIn, "sign in to ChatGPT"),
            (.notSignedIn, "sign in to ChatGPT"), (.planUsageDisabled, "sign in to ChatGPT"),
            (.http(status: 503), "ChatGPT unavailable"),
        ]
        for (error, copy) in cases {
            let e = try env("2026-11-20 08:00")
            let agent = FakeAgent(llm: service(answerFake("x"), db: e.db), error: error)
            _ = try await e.engine.create(ReminderDraft(text: "Summarize my day", action: .prompt,
                                                        schedule: .once(local("2026-11-20 09:00")), origin: .user))
            e.clock.set(local("2026-11-20 09:00"))
            let out = await dispatcher(e, agent: agent).fire()
            #expect(out.map(\.body) == ["Couldn't run “Summarize my day”: \(copy)"])
        }
        // No agent wired: the same copy as an unavailable model.
        let e = try env("2026-11-20 08:00")
        _ = try await e.engine.create(ReminderDraft(text: "Summarize my day", action: .prompt,
                                                    schedule: .once(local("2026-11-20 09:00")), origin: .user))
        e.clock.set(local("2026-11-20 09:00"))
        #expect(await dispatcher(e, agent: nil).fire().map(\.body) == ["Couldn't run “Summarize my day”: ChatGPT unavailable"])
    }

    @Test func reminderDeliveryIsIdempotent() async throws {
        let e = try env("2026-11-20 08:00")
        let r = try await e.engine.create(ReminderDraft(text: "Call Anna", action: .notify,
                                                        schedule: .once(local("2026-11-20 09:00")), origin: .user))
        let firing = Firing(reminder: r, scheduledFor: local("2026-11-20 09:00"), late: false)
        let d = dispatcher(e, agent: nil)
        let g = try DataGeneration.current(e.db)
        let first = try await d.deliver(firing, generation: g)
        let second = try await d.deliver(firing, generation: g)
        #expect(first != nil)
        #expect(second == nil)
        #expect(try inboxRows(e.db).count == 1)
        #expect(try chatRows(e.db).count == 1)
        #expect(e.log.all.count == 1)
    }

    @Test func reminderWipedDuringThePromptIsNotDelivered() async throws {
        let e = try env("2026-11-20 08:00")
        let db = e.db
        let agent = FakeAgent(llm: service(answerFake("answer"), db: e.db),
                              before: { try? DataReset.deleteAllCapturedData(in: db) })
        _ = try await e.engine.create(ReminderDraft(text: "Summarize my day", action: .prompt,
                                                    schedule: .once(local("2026-11-20 09:00")), origin: .user))
        e.clock.set(local("2026-11-20 09:00"))
        let out = await dispatcher(e, agent: agent).fire()
        #expect(out.isEmpty)
        #expect(try inboxRows(e.db).isEmpty)
        #expect(try chatRows(e.db).isEmpty)
        #expect(e.log.all.isEmpty)
    }

    @Test func deletedReminderIsNotDelivered() async throws {
        // A reminder row removed between the firing and the delivery (without a generation bump).
        let e = try env("2026-11-20 08:00")
        let r = try await e.engine.create(ReminderDraft(text: "Call Anna", action: .notify,
                                                        schedule: .once(local("2026-11-20 09:00")), origin: .user))
        try await e.db.writer.write { d in _ = try Reminder.deleteOne(d, key: r.id) }
        let firing = Firing(reminder: r, scheduledFor: local("2026-11-20 09:00"), late: false)
        let out = try await dispatcher(e, agent: nil).deliver(firing, generation: DataGeneration.current(e.db))
        #expect(out == nil)
        #expect(try inboxRows(e.db).isEmpty)
    }

    @Test func nothingDueDeliversNothing() async throws {
        let e = try env("2026-11-20 08:00")
        _ = try await e.engine.create(ReminderDraft(text: "Later", action: .notify,
                                                    schedule: .once(local("2026-11-20 09:00")), origin: .user))
        #expect(await dispatcher(e, agent: nil).fire().isEmpty)
        #expect(try inboxRows(e.db).isEmpty)
    }

    @Test func notifyIsStoredInTheFiringTransaction() async throws {
        let e = try env("2026-11-20 08:00")
        let r = try await e.engine.create(ReminderDraft(text: "Call Anna", action: .notify,
                                                        schedule: .once(local("2026-11-20 09:00")), origin: .user))
        e.clock.set(local("2026-11-20 09:00"))
        // Crash right after the firing committed: the message is already there.
        let committed = try await dispatcher(e, agent: nil).commitFirings()
        #expect(committed.firings.count == 1)
        #expect(try ReminderStore(e.db).get(r.id!)?.status == .done)
        #expect(try inboxRows(e.db).map(\.body) == ["Call Anna"])
        let ids = try inboxRows(e.db).map(\.id)
        #expect(try chatRows(e.db).map(\.inboxID) == ids)
        #expect(e.log.all.isEmpty)   // announced only by fire(), after the commit
        // After a restart nothing is fired or delivered twice.
        #expect(await dispatcher(e, agent: nil).fire().isEmpty)
        #expect(try inboxRows(e.db).count == 1)
        // fire() announces what it stored.
        _ = try await e.engine.create(ReminderDraft(text: "Water plants", action: .notify,
                                                    schedule: .once(local("2026-11-20 09:30")), origin: .user))
        e.clock.set(local("2026-11-20 09:30"))
        #expect(await dispatcher(e, agent: nil).fire().map(\.body) == ["Water plants"])
        #expect(e.log.all.map(\.body) == ["Water plants"])
    }

    @Test func promptFiringLostInACrashIsRecovered() async throws {
        let e = try env("2026-11-20 08:00")
        let agent = FakeAgent(llm: service(answerFake("Your day: 2 meetings."), db: e.db))
        let r = try await e.engine.create(ReminderDraft(text: "Summarize my day", action: .prompt,
                                                        schedule: .once(local("2026-11-20 09:00")), origin: .user))
        e.clock.set(local("2026-11-20 09:00"))
        // Crash after the firing committed, before the answer was delivered.
        _ = try await dispatcher(e, agent: agent).commitFirings()
        #expect(try inboxRows(e.db).isEmpty)
        let pending = try SettingsStore(e.db).value([PendingPrompt].self, forKey: ReminderDispatcher.pendingKey)
        #expect(pending?.map(\.reminderID) == [r.id!])
        #expect(pending?.map(\.scheduledFor) == [local("2026-11-20 09:00")])

        // The next fire() (after a restart) re-delivers it, once.
        e.clock.set(local("2026-11-20 09:05"))
        let out = await dispatcher(e, agent: agent).fire()
        #expect(out.map(\.body) == ["Your day: 2 meetings."])
        #expect(out.first?.dedupeKey == "reminder:\(r.id!):\(Int(local("2026-11-20 09:00").timeIntervalSince1970))")
        #expect(try SettingsStore(e.db).value([PendingPrompt].self, forKey: ReminderDispatcher.pendingKey) == nil)
        #expect(await dispatcher(e, agent: agent).fire().isEmpty)
        #expect(try inboxRows(e.db).count == 1)
        #expect(agent.seen.withLock { $0.count } == 1)
    }

    @Test func promptRecordsOlderThanADayOrAlreadyDeliveredAreDropped() async throws {
        let e = try env("2026-11-20 08:00")
        let agent = FakeAgent(llm: service(answerFake("late"), db: e.db))
        _ = try await e.engine.create(ReminderDraft(text: "Summarize my day", action: .prompt,
                                                    schedule: .once(local("2026-11-20 09:00")), origin: .user))
        e.clock.set(local("2026-11-20 09:00"))
        _ = try await dispatcher(e, agent: agent).commitFirings()
        e.clock.set(local("2026-11-21 09:01"))
        #expect(await dispatcher(e, agent: agent).fire().isEmpty)
        #expect(try inboxRows(e.db).isEmpty)
        #expect(agent.seen.withLock { $0.isEmpty })
        #expect(try SettingsStore(e.db).value([PendingPrompt].self, forKey: ReminderDispatcher.pendingKey) == nil)

        // A record whose message exists (crash after delivery, before the cleanup) is only removed.
        let e2 = try env("2026-11-20 08:00")
        let agent2 = FakeAgent(llm: service(answerFake("once"), db: e2.db))
        _ = try await e2.engine.create(ReminderDraft(text: "Summarize my day", action: .prompt,
                                                     schedule: .once(local("2026-11-20 09:00")), origin: .user))
        e2.clock.set(local("2026-11-20 09:00"))
        let d2 = dispatcher(e2, agent: agent2)
        let committed = try await d2.commitFirings()
        _ = try await d2.deliver(try #require(committed.firings.first), generation: committed.generation)
        #expect(await d2.fire().isEmpty)
        #expect(try inboxRows(e2.db).count == 1)
        #expect(agent2.seen.withLock { $0.count } == 1)
        #expect(try SettingsStore(e2.db).value([PendingPrompt].self, forKey: ReminderDispatcher.pendingKey) == nil)
    }
    @Test func promptRemindersStayUnderTheBudgetAndTheBackoff() async throws {
        for (gate, copy) in [(ReminderPromptGate.budget, "daily background budget reached"),
                             (.backoff, "usage limit reached")] {
            let e = try env("2026-11-20 08:00")
            let agent = FakeAgent(llm: service(answerFake("x"), db: e.db))
            _ = try await e.engine.create(ReminderDraft(text: "Summarize my day", action: .prompt,
                                                        schedule: .once(local("2026-11-20 09:00")), origin: .user))
            e.clock.set(local("2026-11-20 09:00"))
            let d = ReminderDispatcher(engine: e.engine, inbox: makeInbox(e.db, e.log), agent: agent, calendar: { paris },
                                       now: { e.clock.now() }, promptGate: { _ in gate })
            #expect(await d.fire().map(\.body) == ["Couldn't run “Summarize my day”: \(copy)"])
            #expect(agent.seen.withLock { $0.isEmpty })
        }
    }

    @Test func defaultPromptGateReadsTheBudgetAndTheBackoff() async throws {
        let db = try AppDatabase.inMemory()
        let now = local("2026-11-20 09:00")
        #expect(ReminderPromptGate.current(db: db, calendar: paris, now: now) == .allow)
        try MemorySettings(SettingsStore(db)).setBackoff(UsageBackoff(step: 1, until: now.addingTimeInterval(600)))
        #expect(ReminderPromptGate.current(db: db, calendar: paris, now: now) == .backoff)
        #expect(ReminderPromptGate.current(db: db, calendar: paris, now: now.addingTimeInterval(601)) == .allow)
        try MemorySettings(SettingsStore(db)).setBackoff(UsageBackoff())
        // A background call that spends the whole daily budget (calls are stamped with the real clock).
        try MemorySettings(SettingsStore(db)).setDailyTokenBudget(10)
        _ = try await service(answerFake("x"), db: db).complete(.reminderPrompt, instructions: "x", input: [.user("x")])
        #expect(ReminderPromptGate.current(db: db, calendar: .current, now: Date()) == .budget)
    }

    @Test func recoveryDropsCancelledRemindersAndUnreadableLists() async throws {
        let e = try env("2026-11-20 08:00")
        let agent = FakeAgent(llm: service(answerFake("never"), db: e.db))
        let r = try await e.engine.create(ReminderDraft(text: "Summarize my day", action: .prompt,
                                                        schedule: .interval(seconds: 3_600, anchor: local("2026-11-20 09:00")), origin: .user))
        e.clock.set(local("2026-11-20 09:00"))
        _ = try await dispatcher(e, agent: agent).commitFirings()
        _ = try await e.engine.cancel(r.id!)
        e.clock.set(local("2026-11-20 09:05"))
        #expect(await dispatcher(e, agent: agent).fire().isEmpty)
        #expect(agent.seen.withLock { $0.isEmpty })
        #expect(try SettingsStore(e.db).value([PendingPrompt].self, forKey: ReminderDispatcher.pendingKey) == nil)

        // An unreadable list is dropped, not retried forever.
        try await e.db.writer.write { d in
            try d.execute(sql: "INSERT OR REPLACE INTO settings (key, value) VALUES (?, '{broken')",
                          arguments: [ReminderDispatcher.pendingKey])
        }
        #expect(await dispatcher(e, agent: agent).fire().isEmpty)
        let raw = try await e.db.reader.read { d in
            try String.fetchOne(d, sql: "SELECT value FROM settings WHERE key = ?", arguments: [ReminderDispatcher.pendingKey])
        }
        #expect(raw == nil)
    }
}
