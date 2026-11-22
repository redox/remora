import Foundation
import GRDB
import LLM
import LLMTestSupport
import Memory
import Synchronization
import Testing
@testable import Assistant
import Storage

private struct Env {
    var db: AppDatabase
    var fake: FakeLLMClient
    var clock: LiveClock
    var log: DeliveryLog
    var runner: BriefRunner
    var snapshot: Snapshot
}

/// A database with yesterday's day chronicle (so a morning brief has evidence) and today's hour (for
/// the evening wrap). The fake model answers drafts with "You …" and checks with OK, after running
/// `onRequest`.
private func env(_ kind: BriefKind, start: Date, enabled: Bool = true, checks: [String] = [checkOK, checkOK],
                 onRequest: @escaping @Sendable (LLMRequest, AppDatabase, LiveClock) -> Void = { _, _, _ in })
    throws -> Env {
    let db = try AppDatabase.inMemory()
    let s = try seedSnapshot(db, at: local("2026-11-19 15:00"))
    try seedChronicle(db, .day, start: local("2026-11-19 12:00"), summary: "Finished the Oslo deck.", snapshotIDs: [s.id!])
    let s2 = try seedSnapshot(db, at: local("2026-11-20 09:05"))
    try seedChronicle(db, .hour, start: local("2026-11-20 09:00"), summary: "Fixed the export crash.", snapshotIDs: [s2.id!])
    let clock = LiveClock(start)
    let fake = writerFake(drafts: ["You finished the Oslo deck.", "You finished the Oslo deck."], checks: checks,
                          onRequest: { onRequest($0, db, clock) })
    let log = DeliveryLog()
    let runner = BriefRunner(kind: kind, db: db, writer: VerifiedWriter(llm: service(fake, db: db)),
                             inbox: makeInbox(db, log), enabled: { enabled }, now: { clock.now() })
    return Env(db: db, fake: fake, clock: clock, log: log, runner: runner, snapshot: s)
}

private func job(_ kind: BriefKind, day: String) -> Job {
    let d = local("\(day) 12:00")
    let w = kind.window(day: d, calendar: paris)
    return Job(kind: kind == .morning ? .morningBrief : .eveningWrap, periodKey: PeriodKey.key(.day, for: d, calendar: paris),
               periodStart: w.start, periodEnd: w.end, nextRunAt: w.start, createdAt: w.start)
}

@Suite struct BriefRunnerTests {
    @Test func windows() {
        let day = local("2026-11-20 15:00")
        #expect(BriefKind.morning.window(day: day, calendar: paris)
                == DateInterval(start: local("2026-11-20 08:00"), end: local("2026-11-20 12:00")))
        #expect(BriefKind.evening.window(day: day, calendar: paris)
                == DateInterval(start: local("2026-11-20 16:00"), end: local("2026-11-21 00:00")))
    }

    @Test func morningCatchUpUntilNoonOnly() async throws {
        // Started 11:58, the write finishes at 12:10 (inside the 15-min grace): delivered.
        let e = try env(.morning, start: local("2026-11-20 11:58"), onRequest: { r, _, clock in
            if isCheck(r) { clock.set(local("2026-11-20 12:10")) }
        })
        let out = try await e.runner.run(job(.morning, day: "2026-11-20"), context: jobContext(local("2026-11-20 11:58")))
        #expect(out == .done)
        #expect(try inboxRows(e.db).map(\.title) == ["Morning brief"])
        #expect(try inboxRows(e.db).first?.createdAt == local("2026-11-20 12:10"))

        // The write finishes at 12:20, past the grace: skipped, nothing stored.
        let late = try env(.morning, start: local("2026-11-20 11:58"), onRequest: { r, _, clock in
            if isCheck(r) { clock.set(local("2026-11-20 12:20")) }
        })
        let out2 = try await late.runner.run(job(.morning, day: "2026-11-20"), context: jobContext(local("2026-11-20 11:58")))
        #expect(out2 == .skipped("window passed"))
        #expect(try inboxRows(late.db).isEmpty)

        // Started at 12:16: skipped before any model call.
        let after = try env(.morning, start: local("2026-11-20 12:16"))
        let out3 = try await after.runner.run(job(.morning, day: "2026-11-20"), context: jobContext(local("2026-11-20 12:16")))
        #expect(out3 == .skipped("window passed"))
        #expect(after.fake.requests.isEmpty)
    }

    @Test func eveningAfterMidnightSkipped() async throws {
        let e = try env(.evening, start: local("2026-11-21 00:05"))
        let out = try await e.runner.run(job(.evening, day: "2026-11-20"), context: jobContext(local("2026-11-21 00:05")))
        #expect(out == .skipped("window passed"))
        #expect(e.fake.requests.isEmpty)
        #expect(try inboxRows(e.db).isEmpty)

        // At 23:30 the same job is delivered as an evening wrap.
        let ok = try env(.evening, start: local("2026-11-20 23:30"))
        let out2 = try await ok.runner.run(job(.evening, day: "2026-11-20"), context: jobContext(local("2026-11-20 23:30")))
        #expect(out2 == .done)
        let row = try #require(try inboxRows(ok.db).first)
        #expect(row.kind == .eveningWrap)
        #expect(row.title == "Evening wrap-up")
        #expect(row.dedupeKey == "evening_wrap:2026-11-20")
        #expect(try jobTypes(ok.db) == ["evening_wrap", "evidence_check"])
    }

    @Test func briefDeliveredOncePerDay() async throws {
        let e = try env(.morning, start: local("2026-11-20 08:30"))
        let j = job(.morning, day: "2026-11-20")
        #expect(try await e.runner.run(j, context: jobContext(local("2026-11-20 08:30"))) == .done)
        #expect(try await e.runner.run(j, context: jobContext(local("2026-11-20 09:30"))) == .skipped("duplicate"))
        let rows = try inboxRows(e.db)
        #expect(rows.count == 1)
        let m = try #require(rows.first)
        #expect(m.kind == .morningBrief)
        #expect(m.dedupeKey == "morning_brief:2026-11-20")
        #expect(m.body == "You finished the Oslo deck.")
        #expect(m.llmCallIDs == [1, 2])
        let turns = try chatRows(e.db)
        #expect(turns.count == 1)
        #expect(turns.first?.inboxID == m.id)
        #expect(turns.first?.role == .assistant)
        #expect(turns.first?.status == .complete)
        #expect(turns.first?.text == m.body)
        #expect(turns.first?.llmCallIDs == [1, 2])
        #expect(e.log.all.map(\.id) == [m.id])
        // Each call points at the inbox message; the second run made no model call.
        #expect(e.fake.requests.count == 2)
        let tables = try await e.db.reader.read { d in try String.fetchAll(d, sql: "SELECT artifact_table FROM llm_calls ORDER BY id") }
        let artifactIDs = try await e.db.reader.read { d in try Int64.fetchAll(d, sql: "SELECT artifact_id FROM llm_calls ORDER BY id") }
        #expect(tables == ["inbox_messages", "inbox_messages"])
        #expect(artifactIDs == [m.id!, m.id!])
    }

    @Test func deliveryDiscardedAfterDeleteAll() async throws {
        let e = try env(.morning, start: local("2026-11-20 08:30"), onRequest: { r, db, _ in
            if isCheck(r) { try? DataReset.deleteAllCapturedData(in: db) }
        })
        await #expect(throws: DataGeneration.Stale.self) {
            try await e.runner.run(job(.morning, day: "2026-11-20"), context: jobContext(local("2026-11-20 08:30")))
        }
        #expect(try inboxRows(e.db).isEmpty)
        #expect(try chatRows(e.db).isEmpty)
        #expect(e.log.all.isEmpty)
    }

    @Test func forgottenEvidenceDiscardsTheBrief() async throws {
        // Forget does not bump the generation; the delivery re-checks the evidence rows instead.
        let e = try env(.morning, start: local("2026-11-20 08:30"), onRequest: { r, db, _ in
            if isCheck(r) {
                let ids = (try? db.reader.read { d in try Int64.fetchAll(d, sql: "SELECT id FROM snapshots") }) ?? []
                _ = try? SnapshotStore(db).delete(ids: ids)
            }
        })
        let out = try await e.runner.run(job(.morning, day: "2026-11-20"), context: jobContext(local("2026-11-20 08:30")))
        #expect(out == .skipped("evidence changed"))
        #expect(try inboxRows(e.db).isEmpty)
        #expect(e.log.all.isEmpty)
    }

    @Test func exclusionOrMemoryOffDuringTheWriteDiscardsTheBrief() async throws {
        // The evidence's app is excluded while the brief is written: the fresh policy wins.
        let e = try env(.morning, start: local("2026-11-20 08:30"), onRequest: { r, db, _ in
            if isCheck(r) { try? ExclusionStore(db).add("app:Notes") }
        })
        let out = try await e.runner.run(job(.morning, day: "2026-11-20"), context: jobContext(local("2026-11-20 08:30")))
        #expect(out == .skipped("evidence changed"))
        #expect(try inboxRows(e.db).isEmpty && chatRows(e.db).isEmpty)
        #expect(e.log.all.isEmpty)

        // Background memory is turned off while the brief is written.
        let off = try env(.morning, start: local("2026-11-20 08:30"), onRequest: { r, db, _ in
            if isCheck(r) { try? MemorySettings(SettingsStore(db)).setEnabled(false) }
        })
        _ = try await off.runner.run(job(.morning, day: "2026-11-20"), context: jobContext(local("2026-11-20 08:30")))
        #expect(try inboxRows(off.db).isEmpty)
        #expect(off.log.all.isEmpty)
    }

    @Test func gatesSkipBeforeAnyCall() async throws {
        let j = job(.morning, day: "2026-11-20")
        let off = try env(.morning, start: local("2026-11-20 08:30"), enabled: false)
        #expect(try await off.runner.run(j, context: jobContext(local("2026-11-20 08:30"))) == .skipped("disabled"))
        let cloud = try env(.morning, start: local("2026-11-20 08:30"))
        #expect(try await cloud.runner.run(j, context: jobContext(local("2026-11-20 08:30"), cloud: false))
                == .skipped("cloud_denied"))
        let early = try env(.morning, start: local("2026-11-20 07:50"))
        #expect(try await early.runner.run(j, context: jobContext(local("2026-11-20 07:50"))) == .skipped("window passed"))
        for e in [off, cloud, early] { #expect(e.fake.requests.isEmpty) }

        let empty = try env(.morning, start: local("2026-11-24 08:30"))   // Tuesday: last snapshot > 72 h ago
        #expect(try await empty.runner.run(job(.morning, day: "2026-11-24"), context: jobContext(local("2026-11-24 08:30")))
                == .skipped("no activity"))
        #expect(empty.fake.requests.isEmpty)
    }

    @Test func unverifiedBriefIsNotSent() async throws {
        let e = try env(.morning, start: local("2026-11-20 08:30"), checks: [checkBad(["a"]), checkBad(["b"])])
        let out = try await e.runner.run(job(.morning, day: "2026-11-20"), context: jobContext(local("2026-11-20 08:30")))
        #expect(out == .skipped("unverified"))
        #expect(try inboxRows(e.db).isEmpty)
        #expect(e.fake.requests.count == 4)
    }
    @Test func inboxChecksTheFlagAndTheNudgeCap() async throws {
        let db = try AppDatabase.inMemory()
        let s = try seedSnapshot(db, at: local("2026-11-20 09:00"))
        let open = try seedFlag(db, .commitment, "Send the deck", seen: local("2026-11-20 09:00"), snapshotIDs: [s.id!])
        let done = try seedFlag(db, .commitment, "Done thing", status: .done, seen: local("2026-11-20 09:00"),
                                closedAt: local("2026-11-20 09:30"), snapshotIDs: [s.id!])
        let inbox = makeInbox(db)
        let cap = (cap: 3, minGap: 5_400.0, dayStart: local("2026-11-20 00:00"))
        let closed = try await inbox.deliver(kind: .nudge, title: "Nudge", body: "b", dedupeKey: "nudge:\(done.id!)",
                                             callIDs: [], flagID: done.id, expectedGeneration: 0, nudgeCap: cap,
                                             at: local("2026-11-20 10:00"))
        #expect(closed == nil)
        let first = try await inbox.deliver(kind: .nudge, title: "Nudge", body: "b", dedupeKey: "nudge:\(open.id!)",
                                            callIDs: [], flagID: open.id, expectedGeneration: 0, nudgeCap: cap,
                                            evidence: [EvidenceSource(table: "salient_flags", id: open.id!, snapshotIDs: [s.id!])],
                                            at: local("2026-11-20 10:00"))
        #expect(first?.flagID == open.id)
        // Within the 90-minute gap: refused by the cap, nothing written.
        let second = try await inbox.deliver(kind: .nudge, title: "Nudge", body: "b", dedupeKey: "nudge:other",
                                             callIDs: [], expectedGeneration: 0, nudgeCap: cap, at: local("2026-11-20 11:00"))
        #expect(second == nil)
        #expect(try inboxRows(db).count == 1)
        #expect(try chatRows(db).count == 1)
    }

    @Test func skippedBriefRunsAgainOnceThereIsActivity() async throws {
        // On the real scheduler: at 08:00 there is no recent snapshot ("no activity"); a snapshot
        // arrives at 08:10; the plan at 08:31 requeues the skipped brief and the tick delivers it.
        let db = try AppDatabase.inMemory()
        try seedChronicle(db, .day, start: local("2026-11-19 12:00"), summary: "Finished the Oslo deck.", snapshotIDs: [])
        let clock = LiveClock(local("2026-11-20 08:00"))
        let fake = writerFake(drafts: ["You finished the Oslo deck."], checks: [checkOK])
        let runner = BriefRunner(kind: .morning, db: db, writer: VerifiedWriter(llm: service(fake, db: db)),
                                 inbox: makeInbox(db), enabled: { true }, now: { clock.now() })
        let scheduler = MemoryScheduler(db: db, runners: [.morningBrief: runner],
                                        planner: ProactivePlanner(db: db, calendar: paris, enabled: { true }),
                                        calendar: paris, now: { clock.now() })
        func signals(_ t: Date) -> SchedulerSignals {
            SchedulerSignals(now: t, idleSeconds: 10, onPower: true, lowPower: false, accountReady: true,
                             onDeviceAvailable: true, memoryEnabled: true)
        }
        _ = await scheduler.tick(signals(local("2026-11-20 08:00")))
        let skipped = try #require(try JobStore(db).job(kind: .morningBrief, periodKey: "2026-11-20"))
        #expect(skipped.status == .skipped)
        #expect(skipped.lastError == "no activity")
        #expect(fake.requests.isEmpty)

        try seedSnapshot(db, at: local("2026-11-20 08:10"))
        clock.set(local("2026-11-20 08:20"))
        _ = await scheduler.tick(signals(local("2026-11-20 08:20")))   // too soon after the skip
        #expect(try inboxRows(db).isEmpty)
        clock.set(local("2026-11-20 08:31"))
        _ = await scheduler.tick(signals(local("2026-11-20 08:31")))
        #expect(try inboxRows(db).map(\.dedupeKey) == ["morning_brief:2026-11-20"])
        #expect(try JobStore(db).job(kind: .morningBrief, periodKey: "2026-11-20")?.status == .done)
    }
}
