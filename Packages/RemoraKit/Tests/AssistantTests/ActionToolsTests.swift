import Foundation
import GRDB
import LLM
import Retrieval
import Storage
import Synchronization
import Testing
@testable import Assistant

private final class Effects: ActionEffects {
    private let seen = Mutex<[ActionChange]>([])
    var changes: [ActionChange] { seen.withLock { $0 } }
    func didChange(_ c: ActionChange) async { seen.withLock { $0.append(c) } }
}

/// Records every proposal and answers with `answer`; `before` runs first (e.g. a delete-all
/// while the confirmation sheet is up).
private final class ConfirmSpy: Sendable {
    private let seen = Mutex<[ActionProposal]>([])
    let answer: Bool
    let before: @Sendable () -> Void
    init(answer: Bool, before: @escaping @Sendable () -> Void = {}) { self.answer = answer; self.before = before }
    var proposals: [ActionProposal] { seen.withLock { $0 } }
    func ask(_ p: ActionProposal) async -> Bool {
        seen.withLock { $0.append(p) }
        before()
        return answer
    }
}

private struct Env {
    let clock: Clock
    let db: AppDatabase
    let engine: ReminderEngine
    let effects = Effects()

    init(_ now: String = "2026-11-20T10:00:00+01:00") throws {
        clock = Clock(now)
        db = try AppDatabase.inMemory()
        let clock = clock
        engine = ReminderEngine(store: ReminderStore(db), db: db, calendar: { clock.calendar }, now: { clock.now })
    }

    var timeout: Duration = .seconds(600)
    var tools: [any ChatTool] {
        let clock = clock
        return ActionTools.all(reminders: engine, db: db, effects: effects, now: { clock.now }, confirmTimeout: timeout)
    }

    func run(_ name: String, _ arguments: String, tainted: Bool = false, spy: ConfirmSpy = ConfirmSpy(answer: true),
             generation: Int? = nil) async throws -> ToolRun {
        let tool = try #require(tools.first { $0.definition.name == name })
        let context = ToolContext(now: clock.now, calendar: clock.calendar, turnTainted: tainted,
                                  confirm: { await spy.ask($0) }, generation: generation)
        return await tool.run(arguments: arguments, context: context)
    }

    @discardableResult
    func undo(_ run: ToolRun) async throws -> UndoResult {
        let token = try #require(run.receipt?.undo)
        return try await ActionTools.perform(token, generation: run.receipt?.generation, reminders: engine, db: db,
                                             effects: effects)
    }
}

private func object(_ s: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
}

private func status(_ run: ToolRun) throws -> String? { try object(run.output)["status"] as? String }

@Suite struct ActionToolsTests {
    @Test func toolNamesAndSchemasAreStrict() throws {
        let env = try Env()
        let names = env.tools.map(\.definition.name).sorted()
        #expect(names == ["add_exclusion", "cancel_reminder", "correct_wiki", "create_reminder", "forget_snapshots",
                          "list_reminders", "pause_capture", "update_identity", "update_routine", "update_setting"])
        for t in env.tools {
            #expect(t.definition.strict)
            guard case .object(let schema) = t.definition.parameters, case .object(let props)? = schema["properties"],
                  case .array(let required)? = schema["required"] else { Issue.record("schema of \(t.definition.name)"); continue }
            #expect(Set(required.compactMap { if case .string(let s) = $0 { s } else { nil } }) == Set(props.keys))
            #expect(schema["additionalProperties"] == .bool(false))
        }
        let kinds = Dictionary(uniqueKeysWithValues: env.tools.map { ($0.definition.name, $0.kind) })
        #expect(kinds["list_reminders"] == .untrustedRead)  // returns model-written text
        #expect(kinds["forget_snapshots"] == .action(.confirm))
        #expect(kinds["update_identity"] == .action(.confirm))
        #expect(kinds["correct_wiki"] == .action(.confirm))
        #expect(kinds["update_routine"] == .action(.confirm))
        #expect(kinds["add_exclusion"] == .action(.reversible))
    }

    @Test func noToolRemovesExclusions() throws {
        let env = try Env()
        #expect(!env.tools.map(\.definition.name).contains { $0.contains("remove") })
        #expect(!env.tools.map(\.definition.description).contains { $0.lowercased().contains("remove an exclusion") })
    }

    @Test func addExclusionRunsWithoutConfirmWhenUntainted() async throws {
        let env = try Env()
        let spy = ConfirmSpy(answer: false)
        let run = try await env.run("add_exclusion", #"{"pattern":"https://Example.com/path"}"#, spy: spy)
        #expect(!run.isError)
        #expect(try status(run) == "done")
        #expect(spy.proposals.isEmpty)
        #expect(run.confirmed == nil)
        #expect(try ExclusionStore(env.db).all().contains("example.com"))
        #expect(env.effects.changes == [.exclusions])
        #expect(run.receipt?.undo == .removeExclusion("example.com"))

        try await env.undo(run)
        #expect(try !ExclusionStore(env.db).all().contains("example.com"))
    }

    @Test func addingAnExistingExclusionHasNoUndo() async throws {
        let env = try Env()
        try ExclusionStore(env.db).add("example.com")
        let run = try await env.run("add_exclusion", #"{"pattern":"example.com"}"#)
        #expect(try status(run) == "done")
        // Undo must never remove an exclusion the user made.
        #expect(run.receipt?.undo == nil)
        #expect(try ExclusionStore(env.db).all().contains("example.com"))
    }

    @Test func actionsAfterUntrustedReadNeedConfirmation() async throws {
        let env = try Env()
        let spy = ConfirmSpy(answer: false)
        let before = try ExclusionStore(env.db).all()
        let run = try await env.run("add_exclusion", #"{"pattern":"example.com"}"#, tainted: true, spy: spy)
        #expect(!run.isError)
        #expect(try status(run) == "declined_by_user")
        #expect(run.confirmed == false)
        #expect(run.receipt == nil)
        #expect(try ExclusionStore(env.db).all() == before)
        #expect(env.effects.changes.isEmpty)
        let proposal = try #require(spy.proposals.first)
        #expect(spy.proposals.count == 1)
        #expect(proposal.afterUntrustedRead)
        #expect(proposal.tool == "add_exclusion")
        #expect(proposal.summary.contains("example.com"))
    }

    @Test func acceptedAfterUntrustedReadRunsAndSaysSo() async throws {
        let env = try Env()
        let run = try await env.run("pause_capture", #"{"duration":"1h"}"#, tainted: true)
        #expect(try status(run) == "done")
        #expect(run.confirmed == true)
        #expect(try SettingsStore(env.db).pausedUntil() == env.clock.now.addingTimeInterval(3_600))
    }

    @Test func confirmRiskAlwaysAsks() async throws {
        let env = try Env()
        let id = try SnapshotStore(env.db).insert(Snapshot(capturedAt: env.clock.now, app: "Notes", windowTitle: "Doc",
                                                           text: "secret", contentHash: "h", source: .ax)).id!
        let spy = ConfirmSpy(answer: false)
        let run = try await env.run("forget_snapshots", #"{"ids":[\#(id)]}"#, spy: spy)
        #expect(spy.proposals.count == 1)
        #expect(spy.proposals.first?.risk == .confirm)
        #expect(spy.proposals.first?.afterUntrustedRead == false)
        #expect(try status(run) == "declined_by_user")
        #expect(try SnapshotStore(env.db).snapshots(ids: [id]).count == 1)
    }

    @Test func invalidExclusionIsToolError() async throws {
        let env = try Env()
        let spy = ConfirmSpy(answer: true)
        let run = try await env.run("add_exclusion", #"{"pattern":"app:"}"#, tainted: true, spy: spy)
        #expect(run.isError)
        #expect(run.output.contains("app:Name"))
        #expect(run.output.contains("example.com"))
        // Never ask the user about an action that cannot run.
        #expect(spy.proposals.isEmpty)
    }

    @Test func createRecurringReminderFromRRULE() async throws {
        let env = try Env("2026-11-18T10:00:00+01:00")
        let run = try await env.run("create_reminder", """
            {"text":"Weekly review","action":"notify","kind":"recurring","at":"2026-11-20T17:00",
             "rrule":"FREQ=WEEKLY;BYDAY=FR","every_minutes":0}
            """)
        #expect(!run.isError, "\(run.output)")
        let out = try object(run.output)
        #expect(out["status"] as? String == "done")
        #expect(out["schedule"] as? String == "Every Friday at 17:00")
        #expect(out["next_fire_at"] as? String == "2026-11-20T17:00")
        let id = try #require(out["id"] as? Int)
        #expect(run.receipt?.undo == .cancelReminder(Int64(id)))
        #expect(env.effects.changes == [.reminders])
        let stored = try #require(try ReminderStore(env.db).get(Int64(id)))
        #expect(stored.createdBy == .chat)
        #expect(stored.status == .active)

        try await env.undo(run)
        #expect(try ReminderStore(env.db).get(Int64(id))?.status == .cancelled)
    }

    @Test func createOnceAndIntervalReminders() async throws {
        let env = try Env()
        let once = try await env.run("create_reminder", """
            {"text":"Call Anna","action":"notify","kind":"once","at":"2026-11-21T09:30","rrule":"","every_minutes":0}
            """)
        #expect(try object(once.output)["next_fire_at"] as? String == "2026-11-21T09:30")
        let every = try await env.run("create_reminder", """
            {"text":"Stretch","action":"notify","kind":"interval","at":"","rrule":"","every_minutes":90}
            """)
        #expect(try object(every.output)["next_fire_at"] as? String == "2026-11-20T11:30")
        #expect(try object(every.output)["schedule"] as? String == "Every 90 minutes")
        let list = try await env.run("list_reminders", "{}")
        let reminders = try #require(try object(list.output)["reminders"] as? [[String: Any]])
        #expect(reminders.map { $0["text"] as? String } == ["Stretch", "Call Anna"])
    }

    @Test func badRRULEExplainsFix() async throws {
        let env = try Env()
        let run = try await env.run("create_reminder", """
            {"text":"Birthday","action":"notify","kind":"recurring","at":"2026-12-01T09:00","rrule":"FREQ=YEARLY",
             "every_minutes":0}
            """)
        #expect(run.isError)
        #expect(run.output.contains("DAILY, WEEKLY or MONTHLY"))
        #expect(try ReminderStore(env.db).active().isEmpty)
    }

    @Test func reminderErrorsTellTheModelHowToFixThem() async throws {
        let env = try Env()
        let past = try await env.run("create_reminder", """
            {"text":"x","action":"notify","kind":"once","at":"2026-11-20T09:00","rrule":"","every_minutes":0}
            """)
        #expect(past.isError && past.output.contains("future"))
        let short = try await env.run("create_reminder", """
            {"text":"x","action":"prompt","kind":"interval","at":"","rrule":"","every_minutes":30}
            """)
        #expect(short.isError && short.output.contains("60"))
        let badTime = try await env.run("create_reminder", """
            {"text":"x","action":"notify","kind":"once","at":"tomorrow 9am","rrule":"","every_minutes":0}
            """)
        #expect(badTime.isError && badTime.output.contains("yyyy-MM-dd'T'HH:mm"))
    }

    @Test func cancelReminderAndUndoReactivates() async throws {
        let env = try Env()
        let r = try await env.engine.create(ReminderDraft(text: "Call Anna", action: .notify,
                                                          schedule: .once(at("2026-11-21T09:00:00+01:00")), origin: .user))
        let run = try await env.run("cancel_reminder", #"{"id":\#(r.id!)}"#)
        #expect(try status(run) == "done")
        #expect(try ReminderStore(env.db).get(r.id!)?.status == .cancelled)
        #expect(run.receipt?.undo == .reactivateReminder(r.id!))
        try await env.undo(run)
        let back = try #require(try ReminderStore(env.db).get(r.id!))
        #expect(back.status == .active)
        #expect(back.nextFireAt == r.nextFireAt)

        // A reminder that is not active cannot be "cancelled" (its undo would wrongly revive it).
        _ = try await env.engine.cancel(r.id!)
        let again = try await env.run("cancel_reminder", #"{"id":\#(r.id!)}"#)
        #expect(again.isError)
        #expect(try ReminderStore(env.db).get(r.id!)?.status == .cancelled)
    }

    @Test func pauseAndUndoRestoresPrevious() async throws {
        let env = try Env()
        let x = env.clock.now.addingTimeInterval(600)
        try SettingsStore(env.db).pause(until: x)
        let run = try await env.run("pause_capture", #"{"duration":"1h"}"#)
        #expect(try status(run) == "done")
        #expect(try SettingsStore(env.db).pausedUntil() == env.clock.now.addingTimeInterval(3_600))
        #expect(run.receipt?.undo == .restorePause(previous: x, applied: env.clock.now.addingTimeInterval(3_600)))
        try await env.undo(run)
        #expect(try SettingsStore(env.db).pausedUntil() == x)
        #expect(env.effects.changes == [.pause, .pause])

        // Not paused before: undo resumes (removes the key).
        try SettingsStore(env.db).pause(until: nil)
        let second = try await env.run("pause_capture", #"{"duration":"indefinitely"}"#)
        #expect(try SettingsStore(env.db).pausedUntil() == .distantFuture)
        try await env.undo(second)
        #expect(try SettingsStore(env.db).pausedUntil() == nil)
    }

    @Test func shorteningAPauseNeedsConfirmation() async throws {
        let env = try Env()
        try SettingsStore(env.db).pause(until: .distantFuture)
        let spy = ConfirmSpy(answer: false)
        let resume = try await env.run("pause_capture", #"{"duration":"resume"}"#, spy: spy)
        #expect(try status(resume) == "declined_by_user")
        let shorter = try await env.run("pause_capture", #"{"duration":"15m"}"#, spy: spy)
        #expect(try status(shorter) == "declined_by_user")
        #expect(spy.proposals.map(\.risk) == [.confirm, .confirm])
        #expect(try SettingsStore(env.db).pausedUntil() == .distantFuture)

        let accepted = try await env.run("pause_capture", #"{"duration":"resume"}"#)
        #expect(try status(accepted) == "done")
        #expect(try SettingsStore(env.db).pausedUntil() == nil)
        #expect(accepted.receipt?.undo == .restorePause(previous: .distantFuture, applied: nil))
    }

    @Test func updateSettingUndo() async throws {
        let env = try Env()
        try SettingRegistryTestsHelper.set(env.db, "text_size", "100")
        let run = try await env.run("update_setting", #"{"name":"text_size","value":"130"}"#)
        let out = try object(run.output)
        #expect(out["status"] as? String == "done")
        #expect(out["previous"] as? String == "100")
        #expect(out["value"] as? String == "130")
        #expect(try SettingRegistryTestsHelper.get(env.db, "text_size") == "130")
        #expect(run.receipt?.undo == .restoreSetting(name: "text_size", previous: "100", applied: "130"))
        #expect(env.effects.changes == [.setting("text_size")])
        try await env.undo(run)
        #expect(try SettingRegistryTestsHelper.get(env.db, "text_size") == "100")
    }

    @Test func updateSettingUndoRestoresAValueTheModelCouldNotSet() async throws {
        let env = try Env()
        try MemorySettings(SettingsStore(env.db)).setRetention(.days(45))
        let run = try await env.run("update_setting", #"{"name":"raw_capture_retention","value":"90"}"#)
        #expect(run.confirmed == true)
        #expect(MemorySettings(SettingsStore(env.db)).retention() == .days(90))
        try await env.undo(run)
        #expect(MemorySettings(SettingsStore(env.db)).retention() == .days(45))
    }

    @Test func updateSettingRiskComesFromTheEntry() async throws {
        let env = try Env()
        let spy = ConfirmSpy(answer: false)
        let memory = try await env.run("update_setting", #"{"name":"background_memory","value":"off"}"#, spy: spy)
        #expect(try status(memory) == "declined_by_user")
        #expect(MemorySettings(SettingsStore(env.db)).enabled())
        let sounds = try await env.run("update_setting", #"{"name":"sounds","value":"off"}"#, spy: spy)
        #expect(try status(sounds) == "done")
        #expect(spy.proposals.count == 1)
        let bad = try await env.run("update_setting", #"{"name":"exclusions","value":"none"}"#, spy: spy)
        #expect(bad.isError)
        let badValue = try await env.run("update_setting", #"{"name":"text_size","value":"175"}"#, spy: spy)
        #expect(badValue.isError && badValue.output.contains("100"))
    }

    @Test func updateIdentityKeepsUserEdit() async throws {
        let env = try Env()
        try await env.db.writer.write { d in
            _ = try IdentityStore(env.db).insertLLM("- Works on Remora\n- Lives in Paris", llmCallID: nil,
                                                    at: env.clock.now, in: d)
        }
        let spy = ConfirmSpy(answer: true)
        let run = try await env.run("update_identity", #"{"add_lines":["I live in Lyon"],"remove_lines":["lives  IN paris"]}"#,
                                    spy: spy)
        #expect(try status(run) == "done", "\(run.output)")
        #expect(spy.proposals.count == 1)
        #expect(spy.proposals.first?.summary.contains("I live in Lyon") == true)
        let current = try #require(try IdentityStore(env.db).current())
        #expect(current.source == .user)
        #expect(current.llmCallID == nil)
        #expect(current.body.contains("I live in Lyon"))
        #expect(!current.body.contains("Paris"))
        #expect(current.body.contains("Works on Remora"))
        #expect(env.effects.changes == [.identity])
    }

    @Test func correctWikiAddsUserFact() async throws {
        let env = try Env()
        let old = try await env.db.writer.write { d -> WikiFact in
            _ = try WikiStore.insert(WikiPage(slug: "anna", type: .person, title: "Anna", firstSeen: env.clock.now,
                                              lastSeen: env.clock.now, updatedAt: env.clock.now), in: d)
            return try WikiStore.insert(WikiFact(slug: "anna", fact: "Anna lives in Paris", normKey: "anna lives in paris",
                                                 subject: .thirdParty, basis: .onScreenContent, worth: .core,
                                                 validAt: env.clock.now, recordedAt: env.clock.now,
                                                 lastConfirmedAt: env.clock.now), in: d)
        }
        let spy = ConfirmSpy(answer: true)
        let wrong = try await env.run("correct_wiki", #"{"slug":"anna","correction":"x","invalidate_fact_ids":[999]}"#, spy: spy)
        #expect(wrong.isError)
        #expect(spy.proposals.isEmpty)
        let run = try await env.run("correct_wiki", """
            {"slug":"anna","correction":"Anna lives in Lyon","invalidate_fact_ids":[\(old.id!)]}
            """, spy: spy)
        #expect(try status(run) == "done", "\(run.output)")
        #expect(spy.proposals.count == 1)
        let valid = try WikiStore(env.db).validFacts(slug: "anna")
        #expect(valid.map(\.fact) == ["Anna lives in Lyon"])
        #expect(valid.first?.basis == .userStated)
        #expect(env.effects.changes == [.wiki])
    }

    @Test func forgetSnapshotsCascades() async throws {
        let env = try Env()
        let store = SnapshotStore(env.db)
        let gone = try store.insert(Snapshot(capturedAt: env.clock.now, app: "Notes", windowTitle: "Doc", text: "secret",
                                             contentHash: "h1", source: .ax)).id!
        let kept = try store.insert(Snapshot(capturedAt: env.clock.now, app: "Notes", windowTitle: "Doc", text: "other",
                                             contentHash: "h2", source: .ax)).id!
        try await env.db.writer.write { d in
            _ = try WikiStore.insert(WikiPage(slug: "anna", type: .person, title: "Anna", mentionCount: 3,
                                              firstSeen: env.clock.now, lastSeen: env.clock.now, updatedAt: env.clock.now), in: d)
            for (text, ids) in [("Anna is secret", [gone]), ("Anna is known", [gone, kept])] {
                _ = try WikiStore.insert(WikiFact(slug: "anna", fact: text, normKey: TextFold.key(text), subject: .thirdParty,
                                                  basis: .onScreenContent, worth: .core, snapshotIDs: ids,
                                                  validAt: env.clock.now, recordedAt: env.clock.now,
                                                  lastConfirmedAt: env.clock.now), in: d)
            }
        }
        let generation = try DataGeneration.current(env.db)
        let run = try await env.run("forget_snapshots", #"{"ids":[\#(gone)]}"#)
        #expect(try status(run) == "done", "\(run.output)")
        #expect(run.confirmed == true)
        #expect(run.receipt?.undo == nil)
        #expect(try object(run.output)["forgotten"] as? Int == 1)
        #expect(try store.snapshots(ids: [gone, kept]).map(\.id) == [kept])
        #expect(try WikiStore(env.db).validFacts(slug: "anna").map(\.fact) == ["Anna is known"])
        // Forget never bumps the generation (in-flight jobs drop forgotten ids themselves).
        #expect(try DataGeneration.current(env.db) == generation)
        #expect(env.effects.changes == [.snapshots])
        // The forget transaction itself marks the digest dirty and sets the chat watermark.
        let marks = try await env.db.reader.read { d in (ForgetMarks.digestIsDirty(in: d), ForgetMarks.chatForgetAt(in: d)) }
        #expect(marks.0 && marks.1 == env.clock.now)
        #expect(run.receipt?.summary.contains("Earlier chat messages won't be reused; Clear chat removes them from view.") == true)
    }

    @Test func forgetWithholdsTheDigestWithoutARebuild() async throws {
        let env = try Env()
        let gone = try SnapshotStore(env.db).insert(Snapshot(capturedAt: env.clock.now, app: "Notes", text: "secret",
                                                             contentHash: "h1", source: .ax)).id!
        try await env.db.writer.write { d in
            _ = try MemoryDigestStore(env.db).insert(MemoryDigest(body: "Digest naming the secret", createdAt: env.clock.now), in: d)
        }
        #expect(try MemoryContext.base(db: env.db, surface: "chat", now: env.clock.now).digest != nil)
        _ = try await env.run("forget_snapshots", #"{"ids":[\#(gone)]}"#)
        #expect(try MemoryContext.base(db: env.db, surface: "chat", now: env.clock.now).digest == nil)
    }

    @Test func forgetSnapshotsLimitsIDs() async throws {
        let env = try Env()
        let empty = try await env.run("forget_snapshots", #"{"ids":[]}"#)
        #expect(empty.isError)
        let many = try await env.run("forget_snapshots", #"{"ids":[\#((1...21).map(String.init).joined(separator: ","))]}"#)
        #expect(many.isError)
    }

    @Test func actionConfirmedAfterDeleteAllWritesNothing() async throws {
        let env = try Env()
        let db = env.db
        let spy = ConfirmSpy(answer: true, before: { try? DataReset.deleteAllCapturedData(in: db) })
        let run = try await env.run("create_reminder", """
            {"text":"From a wiped chat","action":"notify","kind":"once","at":"2026-11-21T09:00","rrule":"","every_minutes":0}
            """, tainted: true, spy: spy)
        #expect(run.isError)
        #expect(run.receipt == nil)
        #expect(try ReminderStore(db).active().isEmpty)
        #expect(env.effects.changes.isEmpty)

        let identity = try await env.run("update_identity", #"{"add_lines":["I live in Lyon"],"remove_lines":[]}"#, spy: spy)
        #expect(identity.isError)
        #expect(try IdentityStore(db).current() == nil)
    }

    @Test func turnGenerationIsUsedWhenGiven() async throws {
        let env = try Env()
        let generation = try DataGeneration.current(env.db)
        try DataReset.deleteAllCapturedData(in: env.db)
        // The turn started before the delete-all: its action must not run.
        let run = try await env.run("add_exclusion", #"{"pattern":"example.com"}"#, generation: generation)
        #expect(run.isError)
        #expect(try !ExclusionStore(env.db).all().contains("example.com"))
    }

    @Test func undoAfterDeleteAllIsRefused() async throws {
        let env = try Env()
        let r = try await env.engine.create(ReminderDraft(text: "Call Anna", action: .notify,
                                                          schedule: .once(at("2026-11-21T09:00:00+01:00")), origin: .user))
        let run = try await env.run("cancel_reminder", #"{"id":\#(r.id!)}"#)
        try DataReset.deleteAllCapturedData(in: env.db)
        await #expect(throws: DataGeneration.Stale.self) { try await env.undo(run) }
    }

    // MARK: Fix round 1

    @Test func lateConfirmationExpiresAndWritesNothing() async throws {
        let env = try Env()
        let clock = env.clock
        let spy = ConfirmSpy(answer: true, before: { clock.set("2026-11-20T10:10:01+01:00") })
        let run = try await env.run("add_exclusion", #"{"pattern":"example.com"}"#, tainted: true, spy: spy)
        #expect(!run.isError)
        #expect(try status(run) == "confirmation_expired")
        #expect(run.confirmed == false)
        #expect(run.receipt == nil)
        #expect(try !ExclusionStore(env.db).all().contains("example.com"))
        #expect(env.effects.changes.isEmpty)

        // Just under 10 minutes still counts.
        clock.set("2026-11-20T10:00:00+01:00")
        let inTime = ConfirmSpy(answer: true, before: { clock.set("2026-11-20T10:09:59+01:00") })
        let ok = try await env.run("add_exclusion", #"{"pattern":"example.com"}"#, tainted: true, spy: inTime)
        #expect(try status(ok) == "done")
    }

    @Test func unansweredConfirmationTimesOut() async throws {
        var env = try Env()
        env.timeout = .milliseconds(50)
        let tool = try #require(env.tools.first { $0.definition.name == "pause_capture" })
        let context = ToolContext(now: env.clock.now, calendar: env.clock.calendar, turnTainted: true, confirm: { _ in
            // A card nobody answers (it ignores cancellation, like a sheet left open).
            try? await Task.sleep(for: .seconds(30))
            return true
        })
        let started = ContinuousClock.now
        let run = await tool.run(arguments: #"{"duration":"1h"}"#, context: context)
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(try status(run) == "confirmation_expired")
        #expect(run.confirmed == false)
        #expect(try SettingsStore(env.db).pausedUntil() == nil)
    }

    @Test func pauseEndIsComputedWhenItRuns() async throws {
        let env = try Env()
        let clock = env.clock
        let spy = ConfirmSpy(answer: true, before: { clock.set("2026-11-20T10:05:00+01:00") })
        let run = try await env.run("pause_capture", #"{"duration":"1h"}"#, tainted: true, spy: spy)
        #expect(try status(run) == "done")
        #expect(try SettingsStore(env.db).pausedUntil() == at("2026-11-20T11:05:00+01:00"))
    }

    @Test func pauseThatWouldNowShortenIsRefused() async throws {
        let env = try Env()
        let db = env.db
        // Not paused when the card is built ("Pause for 15 minutes"); the user pauses
        // indefinitely from the menu bar while the card is up, then accepts the card.
        let spy = ConfirmSpy(answer: true, before: { try? SettingsStore(db).pause(until: .distantFuture) })
        let run = try await env.run("pause_capture", #"{"duration":"15m"}"#, tainted: true, spy: spy)
        #expect(run.isError)
        #expect(try SettingsStore(db).pausedUntil() == .distantFuture)
        #expect(env.effects.changes.isEmpty)
    }

    @Test func proposalShowsTheFullStoredText() async throws {
        let env = try Env()
        let spy = ConfirmSpy(answer: true)
        let line = "I prefer " + String(repeating: "very ", count: 55) + "short meetings"  // < 300 chars
        let identity = try await env.run("update_identity", #"{"add_lines":["\#(line)"],"remove_lines":[]}"#, spy: spy)
        #expect(try status(identity) == "done")
        let stored = try #require(try IdentityStore(env.db).current()).body
        #expect(stored.contains(line))
        #expect(spy.proposals.last?.summary.contains(line) == true)

        let text = "Prepare " + String(repeating: "the quarterly numbers ", count: 40)
        let reminder = try await env.run("create_reminder", """
            {"text":"\(text)","action":"notify","kind":"once","at":"2026-11-21T09:00","rrule":"","every_minutes":0}
            """, tainted: true, spy: spy)
        #expect(try status(reminder) == "done")
        let storedText = try #require(try ReminderStore(env.db).active().first).text
        #expect(spy.proposals.last?.summary.contains(storedText) == true)

        try await env.db.writer.write { d in
            _ = try WikiStore.insert(WikiPage(slug: "anna", type: .person, title: "Anna", firstSeen: env.clock.now,
                                              lastSeen: env.clock.now, updatedAt: env.clock.now), in: d)
        }
        let correction = "Anna " + String(repeating: "really ", count: 40) + "lives in Lyon"
        let wiki = try await env.run("correct_wiki", """
            {"slug":"anna","correction":"\(correction)","invalidate_fact_ids":[]}
            """, spy: spy)
        #expect(try status(wiki) == "done")
        #expect(try WikiStore(env.db).validFacts(slug: "anna").first?.fact == correction)
        #expect(spy.proposals.last?.summary.contains(correction) == true)
    }

    @Test func forgetCardListsEachCaptureAndRefusesUnknownIDs() async throws {
        let env = try Env()
        let store = SnapshotStore(env.db)
        let a = try store.insert(Snapshot(capturedAt: at("2026-11-19T14:05:00+01:00"), app: "Mail", windowTitle: "Offer letter",
                                          text: "x", contentHash: "h1", source: .ax)).id!
        let b = try store.insert(Snapshot(capturedAt: at("2026-11-20T09:30:00+01:00"), app: "Safari", windowTitle: nil,
                                          text: "y", contentHash: "h2", source: .ax)).id!
        let spy = ConfirmSpy(answer: false)
        let unknown = try await env.run("forget_snapshots", #"{"ids":[\#(a),999]}"#, spy: spy)
        #expect(unknown.isError)
        #expect(unknown.output.contains("999"))
        #expect(spy.proposals.isEmpty)

        _ = try await env.run("forget_snapshots", #"{"ids":[\#(a),\#(b)]}"#, spy: spy)
        let summary = try #require(spy.proposals.first?.summary)
        #expect(summary.contains("Mail"))
        #expect(summary.contains("Offer letter"))
        #expect(summary.contains("2026-11-19 14:05"))
        #expect(summary.contains("Safari"))
        #expect(summary.contains("2026-11-20 09:30"))
    }

    @Test func correctWikiCardQuotesTheFactsItEnds() async throws {
        let env = try Env()
        let old = try await env.db.writer.write { d -> WikiFact in
            _ = try WikiStore.insert(WikiPage(slug: "anna", type: .person, title: "Anna", firstSeen: env.clock.now,
                                              lastSeen: env.clock.now, updatedAt: env.clock.now), in: d)
            return try WikiStore.insert(WikiFact(slug: "anna", fact: "Anna lives in Paris", normKey: "anna lives in paris",
                                                 subject: .thirdParty, basis: .onScreenContent, worth: .core,
                                                 validAt: env.clock.now, recordedAt: env.clock.now,
                                                 lastConfirmedAt: env.clock.now), in: d)
        }
        let spy = ConfirmSpy(answer: false)
        _ = try await env.run("correct_wiki", """
            {"slug":"anna","correction":"Anna lives in Lyon","invalidate_fact_ids":[\(old.id!)]}
            """, spy: spy)
        #expect(spy.proposals.first?.summary.contains("Anna lives in Paris") == true)
    }

    @Test func undoSkipsAValueChangedSince() async throws {
        let env = try Env()
        let pause = try await env.run("pause_capture", #"{"duration":"1h"}"#)
        try SettingsStore(env.db).pause(until: .distantFuture)  // the user changed it since
        #expect(try await env.undo(pause) == .changedSince)
        #expect(try SettingsStore(env.db).pausedUntil() == .distantFuture)

        let size = try await env.run("update_setting", #"{"name":"text_size","value":"130"}"#)
        try SettingRegistryTestsHelper.set(env.db, "text_size", "140")
        #expect(try await env.undo(size) == .changedSince)
        #expect(try SettingRegistryTestsHelper.get(env.db, "text_size") == "140")
        #expect(env.effects.changes == [.pause, .setting("text_size")])

        let sounds = try await env.run("update_setting", #"{"name":"sounds","value":"off"}"#)
        #expect(try await env.undo(sounds) == .done)
        #expect(try SettingRegistryTestsHelper.get(env.db, "sounds") == "on")
    }

    @Test func retentionDecreaseReceiptWarnsAboutPurgedCaptures() async throws {
        let env = try Env()
        let shorter = try await env.run("update_setting", #"{"name":"raw_capture_retention","value":"7"}"#)
        #expect(shorter.receipt?.summary.contains("can't be restored") == true)
        let longer = try await env.run("update_setting", #"{"name":"raw_capture_retention","value":"forever"}"#)
        #expect(longer.receipt?.summary.contains("can't be restored") == false)
    }

    @Test func retentionCutCardWarnsBeforeAnythingIsPurged() async throws {
        let env = try Env()
        let spy = ConfirmSpy(answer: false)
        _ = try await env.run("update_setting", #"{"name":"raw_capture_retention","value":"7"}"#, spy: spy)
        #expect(spy.proposals.first?.summary.contains("Captures older than 7 days will be deleted") == true)
        let longer = ConfirmSpy(answer: false)
        _ = try await env.run("update_setting", #"{"name":"raw_capture_retention","value":"90"}"#, spy: longer)
        #expect(longer.proposals.first?.summary.contains("will be deleted") == false)
    }

    @Test func longPatternsAndTitlesAreCapped() async throws {
        let env = try Env()
        let spy = ConfirmSpy(answer: true)
        let long = try await env.run("add_exclusion", #"{"pattern":"title:\#(String(repeating: "a", count: 200))"}"#, spy: spy)
        #expect(long.isError && long.output.contains("too long"))
        #expect(try ExclusionStore(env.db).all().isEmpty)

        let title = String(repeating: "T", count: 500)
        try await env.db.writer.write { d in
            _ = try WikiStore.insert(WikiPage(slug: "long", type: .project, title: title, firstSeen: env.clock.now,
                                              lastSeen: env.clock.now, updatedAt: env.clock.now), in: d)
        }
        let wiki = ConfirmSpy(answer: true)
        let run = try await env.run("correct_wiki", #"{"slug":"long","correction":"x","invalidate_fact_ids":[]}"#, spy: wiki)
        let card = try #require(wiki.proposals.first?.summary)
        #expect(!card.contains(title) && card.contains(String(repeating: "T", count: 199) + "…"))
        #expect(run.receipt.map { !$0.summary.contains(title) } == true)
    }

    @Test func badArgumentsAreToolErrors() async throws {
        let env = try Env()
        for (name, args) in [("add_exclusion", "[1]"), ("pause_capture", #"{"duration":"forever"}"#),
                             ("cancel_reminder", #"{"id":"x"}"#), ("update_identity", #"{"add_lines":[],"remove_lines":[]}"#),
                             ("correct_wiki", #"{"slug":"nobody","correction":"x","invalidate_fact_ids":[]}"#)] {
            let run = try await env.run(name, args)
            #expect(run.isError, "\(name)")
        }
        #expect(env.effects.changes.isEmpty)
    }
}

/// Registry access shared with `SettingRegistryTests`.
enum SettingRegistryTestsHelper {
    static func get(_ db: AppDatabase, _ name: String) throws -> String {
        let e = try #require(SettingRegistry.entry(name))
        return try db.reader.read { d in try e.get(SettingsStore(db), d) }
    }

    static func set(_ db: AppDatabase, _ name: String, _ value: String) throws {
        let e = try #require(SettingRegistry.entry(name))
        try db.writer.write { d in try e.set(SettingsStore(db), d, value) }
    }
}
