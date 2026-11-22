import Foundation
import Synchronization
import GRDB
import Testing
import LLM
import Storage
@testable import Memory

/// The clock is fixed unless a test passes one it advances.
private func scheduler(_ db: AppDatabase, _ runner: FakeRunner, kinds: [JobKind] = JobKind.allCases,
                       planner: (any JobPlanning)? = nil, timeout: Duration = .seconds(300),
                       clock: TestClock = TestClock()) -> MemoryScheduler {
    MemoryScheduler(db: db, runners: runners(runner, for: kinds), planner: planner, calendar: paris,
                    jobTimeout: timeout, now: { clock.now() })
}

private func job(_ db: AppDatabase, _ kind: JobKind, _ key: String) throws -> Job {
    try #require(try JobStore(db).job(kind: kind, periodKey: key))
}

@Test func budgetExhaustedStopsCloudJobsOnly() async throws {
    let db = try AppDatabase.inMemory()
    try seedUsage(db, tokens: 750_000)
    try enqueue(db, .hour, "2026-11-20T10+0100", start: date(2026, 11, 20, 10))
    try enqueue(db, .timeLedger, "2026-11-20T10+0100", start: date(2026, 11, 20, 10))
    let runner = FakeRunner()
    let report = await scheduler(db, runner).tick(signals(idle: 300))
    #expect(report.ran == [.timeLedger] && runner.kinds == [.timeLedger])
    #expect(report.stoppedForBudget && !report.postponedForLimit)
    #expect(try job(db, .hour, "2026-11-20T10+0100").status == .pending)
    #expect(try job(db, .timeLedger, "2026-11-20T10+0100").status == .done)
}

/// F-8: compaction and working memory still run past the budget, without the cloud.
@Test func exhaustedBudgetRunsCompactionAndWorkingMemoryWithoutCloud() async throws {
    let db = try AppDatabase.inMemory()
    try seedUsage(db, tokens: 800_000)
    try enqueue(db, .workingMemory, "2026-11-20T13+0100:50")
    try enqueue(db, .compaction, "2026-11-20")
    let runner = FakeRunner()
    let report = await scheduler(db, runner).tick(signals(idle: 300))
    #expect(report.ran == [.workingMemory, .compaction])
    #expect(runner.calls.allSatisfy { !$0.context.cloudAllowed })
}

@Test func softBudgetKeepsHourButHoldsWiki() async throws {
    let db = try AppDatabase.inMemory()
    try seedUsage(db, tokens: 650_000)
    try enqueue(db, .hour, "2026-11-20T10+0100", start: date(2026, 11, 20, 10))
    try enqueue(db, .wikiRewrite, "2026-11-20T09+0100")
    try enqueue(db, .compaction, "2026-11-20")
    let runner = FakeRunner()
    let report = await scheduler(db, runner).tick(signals(idle: 300))
    #expect(report.ran == [.hour, .compaction] && report.stoppedForBudget)
    #expect(runner.calls.allSatisfy { $0.context.cloudAllowed })   // compaction: budget < 100 %
    #expect(try job(db, .wikiRewrite, "2026-11-20T09+0100").status == .pending)
}

@Test(arguments: [LLMError.notSignedIn, .needsSignIn, .planUsageDisabled, .notEligible, .unauthorized, .forbidden,
                  .configuration(code: "chatpass_v2_scope_not_authorized")])
func notSignedInPostponesWithoutAttempt(error: LLMError) async throws {
    let db = try AppDatabase.inMemory()
    try enqueue(db, .hour, "a", start: date(2026, 11, 20, 9))
    try enqueue(db, .hour, "b", start: date(2026, 11, 20, 10))
    let runner = FakeRunner { _, _ in throw error }
    let report = await scheduler(db, runner).tick(signals(idle: 300))
    #expect(report.ran == [.hour])                 // the tick stops at the account error
    let a = try job(db, .hour, "a")
    #expect(a.status == .pending && a.attempts == 0 && a.nextRunAt == t0 + 900 && a.lastError == error.errorCode)
    #expect(try job(db, .hour, "b").nextRunAt < t0)
    #expect(MemorySettings(SettingsStore(db)).backoff() == UsageBackoff())   // not a usage limit
}

/// F-7: an unavailable on-device model skips the job instead of burning attempts.
@Test func onDeviceUnavailableSkipsJob() async throws {
    let db = try AppDatabase.inMemory()
    try enqueue(db, .workingMemory, "slot")
    try seedUsage(db, tokens: 800_000)
    let runner = FakeRunner { _, _ in throw LLMError.onDeviceUnavailable(reason: "Apple Intelligence is off") }
    _ = await scheduler(db, runner).tick(signals(idle: 300))
    let j = try job(db, .workingMemory, "slot")
    #expect(j.status == .skipped && j.attempts == 0 && j.lastError == "on_device_unavailable")
}

@Test func resultDiscardedWhenGenerationChanged() async throws {
    let db = try AppDatabase.inMemory()
    try enqueue(db, .hour, "2026-11-20T09+0100", start: date(2026, 11, 20, 9))
    try enqueue(db, .hour, "2026-11-20T10+0100", start: date(2026, 11, 20, 10))
    // An expired backoff: a completed cloud call would normally reset (rewrite) it.
    var b = UsageBackoff(); b.recordLimit(at: t0 - 7_200)
    try MemorySettings(SettingsStore(db)).setBackoff(b)
    let runner = FakeRunner { job, ctx in
        guard job.periodKey == "2026-11-20T09+0100" else { return .done }
        try seedUsage(db, tokens: 10, at: ctx.now)          // the model call completed…
        try DataReset.deleteAllCapturedData(in: db)          // …then "Delete all data" landed
        // New work queued after the delete-all: a tick that did not stop would run it.
        _ = try JobStore(db).enqueue([JobSpec(kind: .hour, periodKey: "after-reset", periodStart: t0,
                                              periodEnd: t0 + 3_600, notBefore: t0 - 60)], now: t0)
        // The job's generation-checked write is refused.
        try DataGeneration.write(db, expected: ctx.generation) { d in
            var c = Chronicle(level: .hour, periodKey: "2026-11-20T09+0100", periodStart: ctx.now,
                              periodEnd: ctx.now, summary: "late", generatedAt: ctx.now)
            try c.insert(d)
        }
        return .done
    }
    let report = await scheduler(db, runner).tick(signals(idle: 300))
    #expect(report.ran == [.hour])   // the tick stopped at the stale result
    let (jobs, chronicles) = try await db.reader.read { d in (try Job.fetchAll(d), try Chronicle.fetchCount(d)) }
    #expect(chronicles == 0)
    #expect(jobs.map(\.periodKey) == ["after-reset"] && jobs.first?.status == .pending && jobs.first?.attempts == 0)
    // Delete-all removed `memory.backoff`; the stale job must not write a reset backoff back.
    #expect(try SettingsStore(db).value(UsageBackoff.self, forKey: MemorySettings.backoffKey) == nil)
}

/// A runner that returns `.done` after a delete-all (no write of its own to refuse): the
/// scheduler's own recording is generation-checked, so neither the job row nor a reset
/// backoff comes back.
@Test func successAfterDeleteAllRecordsNothing() async throws {
    let db = try AppDatabase.inMemory()
    try enqueue(db, .hour, "h", start: t0)
    var b = UsageBackoff(); b.recordLimit(at: t0 - 7_200)
    try MemorySettings(SettingsStore(db)).setBackoff(b)
    let runner = FakeRunner { _, ctx in
        try seedUsage(db, tokens: 10, at: ctx.now)
        try DataReset.deleteAllCapturedData(in: db)
        return .done
    }
    _ = await scheduler(db, runner).tick(signals(idle: 300))
    #expect(try await db.reader.read { try Job.fetchCount($0) } == 0)
    #expect(try SettingsStore(db).value(UsageBackoff.self, forKey: MemorySettings.backoffKey) == nil)
}

/// A delete-all that lands between planning and enqueueing drops the planned specs.
@Test func plannedJobsDiscardedWhenDataDeletedDuringPlanning() async throws {
    struct DeletingPlanner: JobPlanning {
        let db: AppDatabase
        func plan(_ s: SchedulerSignals) throws -> JobPlan {
            let specs = [JobSpec(kind: .hour, periodKey: "2026-11-20T12+0100", periodStart: date(2026, 11, 20, 12),
                                 periodEnd: date(2026, 11, 20, 13), notBefore: date(2026, 11, 20, 13, 5))]
            try DataReset.deleteAllCapturedData(in: db)
            return JobPlan(specs: specs, watermark: date(2026, 11, 20, 13),
                           requeues: [JobRef(kind: .dayRollup, periodKey: "2026-11-19")])
        }
    }
    let db = try AppDatabase.inMemory()
    let runner = FakeRunner()
    let report = await scheduler(db, runner, planner: DeletingPlanner(db: db)).tick(signals(idle: 300))
    #expect(try await db.reader.read { try Job.fetchCount($0) } == 0)
    #expect(report.ran.isEmpty && runner.calls.isEmpty)
    // (b) neither the watermark nor the requeues were written.
    #expect(try SettingsStore(db).value(Date.self, forKey: JobPlanner.watermarkKey) == nil)
}

/// Times come from the clock when each job runs, not from the tick's start.
@Test func usageLimitLateInTickUsesClockAtLimit() async throws {
    let db = try AppDatabase.inMemory()
    try enqueue(db, .hour, "a", start: date(2026, 11, 20, 9))
    try enqueue(db, .hour, "b", start: date(2026, 11, 20, 10))
    let clock = TestClock()
    let runner = FakeRunner { job, _ in
        if job.periodKey == "a" {
            clock.advance(1_800)   // a slow first job
            return .done
        }
        throw LLMError.usageLimit
    }
    let report = await scheduler(db, runner, clock: clock).tick(signals(idle: 300))
    #expect(report.ran == [.hour, .hour] && report.postponedForLimit)
    #expect(runner.calls.map(\.context.now) == [t0, t0 + 1_800])
    let b = try job(db, .hour, "b")
    #expect(b.nextRunAt == t0 + 1_800 + 900 && b.attempts == 0)
    #expect(MemorySettings(SettingsStore(db)).backoff().until == t0 + 1_800 + 900)
    #expect(try job(db, .hour, "a").updatedAt == t0 + 1_800)   // recorded when it finished
}

@Test func retryDelayCountsFromClockAtFailure() async throws {
    let db = try AppDatabase.inMemory()
    try enqueue(db, .hour, "a", start: date(2026, 11, 20, 9))
    let clock = TestClock()
    let runner = FakeRunner { _, _ in
        clock.advance(600)
        throw LLMError.http(status: 500)
    }
    _ = await scheduler(db, runner, clock: clock).tick(signals(idle: 300))
    // The job started at t0; it failed (and is recorded) on the next job read of the clock.
    let a = try job(db, .hour, "a")
    #expect(a.attempts == 1 && a.nextRunAt == t0 + 600 + 300)
}

/// A requeue made while the job runs (planner, "Run now") wins over the run's result.
@Test(arguments: [false, true])
func requeueDuringRunWins(fails: Bool) async throws {
    let db = try AppDatabase.inMemory()
    try enqueue(db, .hour, "h", start: t0)
    let requeuedAt = t0 + 30
    let runner = FakeRunner { job, _ in
        try JobStore(db).requeue(kind: job.kind, periodKey: job.periodKey, now: requeuedAt)
        if fails { throw LLMError.http(status: 500) }
        return .done
    }
    _ = await scheduler(db, runner, kinds: [.hour]).tick(signals(idle: 5))
    let h = try job(db, .hour, "h")
    #expect(h.status == .pending && h.attempts == 0 && h.nextRunAt == requeuedAt && h.lastError == nil)
}

/// If the result cannot be recorded, the row does not stay `running` until the next launch.
@Test func unrecordedResultReturnsJobToPending() async throws {
    let db = try AppDatabase.inMemory()
    let queued = try enqueue(db, .hour, "h", start: t0)
    let runner = FakeRunner { _, _ in
        // The generation becomes unreadable mid-run, so the generation-checked record fails.
        try await db.writer.write {
            try $0.execute(sql: "INSERT OR REPLACE INTO settings (key, value) VALUES ('memory.dataGeneration', 'x')")
        }
        return .done
    }
    let report = await scheduler(db, runner).tick(signals(idle: 300))
    #expect(report.ran == [.hour])
    let h = try job(db, .hour, "h")
    #expect(h.status == .pending && h.attempts == 0 && h.nextRunAt == queued.nextRunAt)
}

@Test(arguments: [(10.0, 1), (59.0, 1), (300.0, 5)])
func idleRunsManyActiveRunsOne(idle: TimeInterval, expected: Int) async throws {
    let db = try AppDatabase.inMemory()
    for (i, key) in hourKeys(5).enumerated() { try enqueue(db, .hour, key, start: date(2026, 11, 20, i)) }
    let runner = FakeRunner()
    let report = await scheduler(db, runner).tick(signals(idle: idle))
    #expect(report.ran.count == expected)
    // Oldest hour first.
    #expect(runner.calls.first?.job.periodKey == "2026-11-20T00+0100")
}

@Test func idleCapsAtTwentyJobsPerTick() async throws {
    let db = try AppDatabase.inMemory()
    for i in 0..<25 { try enqueue(db, .hour, "h\(i)", start: t0.addingTimeInterval(Double(i) * -3_600)) }
    let report = await scheduler(db, FakeRunner()).tick(signals(idle: 3_600))
    #expect(report.ran.count == 20)
}

@Test func compactionWaitsForIdleAndPower() async throws {
    let db = try AppDatabase.inMemory()
    try enqueue(db, .compaction, "2026-11-20", notBefore: date(2026, 11, 20, 3))
    let runner = FakeRunner()
    let s = scheduler(db, runner)
    #expect(await s.tick(signals(idle: 300, onPower: false)).ran.isEmpty)
    #expect(await s.tick(signals(idle: 30, onPower: true)).ran.isEmpty)
    #expect(await s.tick(signals(idle: 300, onPower: true, lowPower: true)).ran.isEmpty)
    #expect(await s.tick(signals(idle: 300, onPower: true)).ran == [.compaction])
}

@Test func overdueCompactionFallsBackToIdle() async throws {
    let db = try AppDatabase.inMemory()
    try enqueue(db, .compaction, "2026-11-19", notBefore: date(2026, 11, 19, 3))   // 35 h overdue
    let runner = FakeRunner()
    let s = scheduler(db, runner)
    #expect(await s.tick(signals(idle: 30, onPower: false)).ran.isEmpty)
    #expect(await s.tick(signals(idle: 300, onPower: false)).ran == [.compaction])
}

@Test func idleKindsWaitForIdle() async throws {
    let db = try AppDatabase.inMemory()
    try enqueue(db, .identity, "2026-W47")
    let s = scheduler(db, FakeRunner())
    #expect(await s.tick(signals(idle: 119)).ran.isEmpty)
    #expect(await s.tick(signals(idle: 120)).ran == [.identity])
}

@Test func memoryDisabledRunsOnlyLedgerAndCompaction() async throws {
    let db = try AppDatabase.inMemory()
    for k in JobKind.allCases { try enqueue(db, k, "key-\(k.rawValue)", start: t0.addingTimeInterval(-7_200)) }
    let runner = FakeRunner()
    let report = await scheduler(db, runner).tick(signals(idle: 3_600, enabled: false))
    #expect(report.ran == [.timeLedger, .compaction])
    #expect(runner.calls.allSatisfy { !$0.context.cloudAllowed })
    #expect(try JobStore(db).counts() == [.done: 2, .pending: JobKind.allCases.count - 2])
}

@Test func accountNotReadyHoldsCloudJobs() async throws {
    let db = try AppDatabase.inMemory()
    try enqueue(db, .hour, "h", start: t0)
    try enqueue(db, .embeddings, "e")
    let runner = FakeRunner()
    let report = await scheduler(db, runner).tick(signals(idle: 300, account: false))
    #expect(report.ran == [.embeddings])
    #expect(try job(db, .hour, "h").status == .pending)
}

@Test func contextCarriesGenerationLanguageAndCalendar() async throws {
    let db = try AppDatabase.inMemory()
    try DataReset.deleteAllCapturedData(in: db)   // generation 1
    try MemorySettings(SettingsStore(db)).setLanguage(.fr)
    try enqueue(db, .hour, "h", start: t0)
    let runner = FakeRunner()
    _ = await scheduler(db, runner).tick(signals(idle: 300))
    let ctx = try #require(runner.calls.first?.context)
    #expect(ctx.generation == 1 && ctx.language == .fr && ctx.calendar == paris && ctx.now == t0 && ctx.cloudAllowed)
}

@Test func skippedOutcomeIsRecorded() async throws {
    let db = try AppDatabase.inMemory()
    try enqueue(db, .hour, "h", start: t0)
    _ = await scheduler(db, FakeRunner { _, _ in .skipped("no_evidence") }).tick(signals(idle: 300))
    let j = try job(db, .hour, "h")
    #expect(j.status == .skipped && j.lastError == "no_evidence")
}

/// F-60: `last_error` holds codes, never an error's description.
@Test func otherErrorsRetryWithCodeOnly() async throws {
    let db = try AppDatabase.inMemory()
    try enqueue(db, .hour, "a", start: date(2026, 11, 20, 9))
    try enqueue(db, .hour, "b", start: date(2026, 11, 20, 10))
    try enqueue(db, .hour, "c", start: date(2026, 11, 20, 11))
    let runner = FakeRunner { job, _ in
        switch job.periodKey {
        case "a": throw LeakyError()
        case "b": throw CodedFailure()
        default: throw LLMError.badRequest(code: nil, param: "secret param")
        }
    }
    let report = await scheduler(db, runner).tick(signals(idle: 300))
    #expect(report.ran.count == 3)   // a retry does not stop the tick
    #expect(try job(db, .hour, "a").lastError == "LeakyError")
    #expect(try job(db, .hour, "b").lastError == "schema_drift")
    #expect(try job(db, .hour, "c").lastError == "bad_request")
    for key in ["a", "b", "c"] {
        let j = try job(db, .hour, key)
        #expect(j.status == .pending && j.attempts == 1 && j.nextRunAt == t0 + 300)
    }
}

@Test func timeoutCountsAsRetry() async throws {
    let db = try AppDatabase.inMemory()
    try enqueue(db, .hour, "h", start: t0)
    let runner = FakeRunner { _, _ in
        try await Task.sleep(for: .seconds(30))
        return .done
    }
    let started = ContinuousClock.now
    _ = await scheduler(db, runner, timeout: .milliseconds(50)).tick(signals(idle: 300))
    #expect(ContinuousClock.now - started < .seconds(10))
    let j = try job(db, .hour, "h")
    #expect(j.status == .pending && j.attempts == 1 && j.lastError == "timeout")
}

@Test func cancelCurrentReturnsJobToPendingWithoutAttempt() async throws {
    let db = try AppDatabase.inMemory()
    try enqueue(db, .hour, "a", start: date(2026, 11, 20, 9))
    try enqueue(db, .hour, "b", start: date(2026, 11, 20, 10))
    let started = AsyncStream<Void>.makeStream()
    let runner = FakeRunner { _, _ in
        started.continuation.yield()
        try await Task.sleep(for: .seconds(30))
        return .done
    }
    let s = scheduler(db, runner)
    let tick = Task { await s.tick(signals(idle: 300)) }
    var it = started.stream.makeAsyncIterator()
    _ = await it.next()
    await s.cancelCurrent()
    let report = await tick.value
    #expect(report.ran == [.hour])   // the tick stopped after the cancelled job
    let a = try job(db, .hour, "a")
    #expect(a.status == .pending && a.attempts == 0 && a.nextRunAt < t0)
    #expect(try job(db, .hour, "b").status == .pending)
}

@Test func overlappingTickIsANoOp() async throws {
    let db = try AppDatabase.inMemory()
    try enqueue(db, .hour, "a", start: t0)
    let started = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    let runner = FakeRunner { _, _ in
        started.continuation.yield()
        var r = release.stream.makeAsyncIterator()
        _ = await r.next()
        return .done
    }
    let s = scheduler(db, runner)
    let first = Task { await s.tick(signals(idle: 300)) }
    var it = started.stream.makeAsyncIterator()
    _ = await it.next()
    let second = await s.tick(signals(idle: 300))
    #expect(second == TickReport())
    release.continuation.yield()
    #expect(await first.value.ran == [.hour])
}

@Test func launchResetsRunningJobs() async throws {
    let db = try AppDatabase.inMemory()
    let j = try enqueue(db, .hour, "h", start: t0)
    try JobStore(db).markRunning(id: j.id!, now: t0)
    let s = scheduler(db, FakeRunner())
    try await s.launch(now: t0)
    #expect(try job(db, .hour, "h").status == .pending)
}

@Test func kindsWithoutRunnerAreIgnored() async throws {
    let db = try AppDatabase.inMemory()
    try enqueue(db, .hour, "h", start: t0)
    try enqueue(db, .timeLedger, "l", start: t0)
    let runner = FakeRunner()
    let report = await scheduler(db, runner, kinds: [.timeLedger]).tick(signals(idle: 300))
    #expect(report.ran == [.timeLedger])
}

private struct StubPlanner: JobPlanning {
    var specs: [JobSpec] = []
    var watermark: Date?
    var requeues: [JobRef] = []
    func plan(_ s: SchedulerSignals) throws -> JobPlan { JobPlan(specs: specs, watermark: watermark, requeues: requeues) }
}

@Test func tickEnqueuesPlannedJobsThenRunsThem() async throws {
    let db = try AppDatabase.inMemory()
    let planner = StubPlanner(specs: [
        JobSpec(kind: .hour, periodKey: "2026-11-20T12+0100", periodStart: date(2026, 11, 20, 12),
                periodEnd: date(2026, 11, 20, 13), notBefore: date(2026, 11, 20, 13, 5)),
        JobSpec(kind: .styleNotes, periodKey: "2026-11-21", notBefore: date(2026, 11, 21, 4)),   // not yet due
    ])
    let runner = FakeRunner()
    let report = await scheduler(db, runner, planner: planner).tick(signals(idle: 300))
    #expect(report.ran == [.hour])
    #expect(try JobStore(db).counts() == [.done: 1, .pending: 1])
}

/// F-9: "Run now" waives the run condition, never the budget or the backoff.
@Test func runNowWaivesRunConditionOnly() async throws {
    let db = try AppDatabase.inMemory()
    let runner = FakeRunner()
    let s = scheduler(db, runner)
    // Active user, on battery: compaction would never run on a tick.
    let ran = await s.runNow(kind: .compaction, periodKey: "2026-11-20", signals: signals(idle: 5, onPower: false))
    #expect(ran.ran == [.compaction] && runner.kinds == [.compaction])
    #expect(try job(db, .compaction, "2026-11-20").status == .done)

    // Done jobs are requeued and run again.
    let again = await s.runNow(kind: .compaction, periodKey: "2026-11-20", signals: signals(idle: 5))
    #expect(again.ran == [.compaction])

    // Identity past the budget: held, still pending.
    try seedUsage(db, tokens: 750_000)
    let held = await s.runNow(kind: .identity, periodKey: "2026-W47", signals: signals(idle: 5))
    #expect(held.ran.isEmpty && held.stoppedForBudget)
    #expect(try job(db, .identity, "2026-W47").status == .pending)

    // Backoff: held too.
    var b = UsageBackoff(); b.recordLimit(at: t0)
    try MemorySettings(SettingsStore(db)).setBackoff(b)
    try await db.writer.write { try $0.execute(sql: "DELETE FROM llm_calls") }
    let limited = await s.runNow(kind: .identity, periodKey: "2026-W47", signals: signals(idle: 5))
    #expect(limited.ran.isEmpty && limited.postponedForLimit)
    // Only that job runs, even when others are due.
    try enqueue(db, .hour, "h", start: t0)
    try MemorySettings(SettingsStore(db)).setBackoff(UsageBackoff())
    let one = await s.runNow(kind: .identity, periodKey: "2026-W47", signals: signals(idle: 3_600))
    #expect(one.ran == [.identity])
    #expect(try job(db, .hour, "h").status == .pending)
}

@Test func corruptGenerationRunsNothing() async throws {
    let db = try AppDatabase.inMemory()
    try enqueue(db, .timeLedger, "l", start: t0)
    try await db.writer.write {
        try $0.execute(sql: "INSERT INTO settings (key, value) VALUES ('memory.dataGeneration', 'x')")
    }
    let runner = FakeRunner()
    let report = await scheduler(db, runner).tick(signals(idle: 300))
    #expect(report.ran.isEmpty && runner.calls.isEmpty)
}

/// (c) The specs, the watermark and the requeues commit together.
@Test func planCommitsSpecsWatermarkAndRequeuesTogether() async throws {
    let db = try AppDatabase.inMemory()
    try enqueue(db, .dayRollup, "2026-11-19", start: date(2026, 11, 19))
    let id = try #require(try JobStore(db).job(kind: .dayRollup, periodKey: "2026-11-19")?.id)
    try JobStore(db).complete(id: id, status: .done, now: t0)
    let planner = StubPlanner(
        specs: [JobSpec(kind: .styleNotes, periodKey: "2026-11-21", notBefore: date(2026, 11, 21, 4))],
        watermark: date(2026, 11, 20, 13), requeues: [JobRef(kind: .dayRollup, periodKey: "2026-11-19")])
    _ = await scheduler(db, FakeRunner(), kinds: [], planner: planner).tick(signals(idle: 300))
    #expect(try JobStore(db).job(kind: .styleNotes, periodKey: "2026-11-21") != nil)
    #expect(try SettingsStore(db).value(Date.self, forKey: JobPlanner.watermarkKey) == date(2026, 11, 20, 13))
    #expect(try JobStore(db).job(kind: .dayRollup, periodKey: "2026-11-19")?.status == .pending)
}

/// (a) A failing enqueue rolls the whole plan back: the watermark stays and the next tick replans.
@Test func failedEnqueueKeepsWatermarkAndNextTickReplansTheHours() async throws {
    let db = try AppDatabase.inMemory()
    // Planner whose watermark advances; the jobs table rejects the insert (trigger), as a full disk would.
    try await db.writer.write { d in
        try d.execute(sql: "CREATE TRIGGER fail_hour BEFORE INSERT ON jobs WHEN NEW.kind = 'hour' BEGIN SELECT RAISE(ABORT, 'boom'); END")
    }
    struct Hourly: JobPlanning {
        let db: AppDatabase
        func plan(_ s: SchedulerSignals) throws -> JobPlan {
            let wm = try SettingsStore(db).value(Date.self, forKey: JobPlanner.watermarkKey)
            // Replans the 12:00 hour until the watermark moves past it.
            guard wm == nil else { return JobPlan() }
            return JobPlan(specs: [JobSpec(kind: .hour, periodKey: "2026-11-20T12+0100", periodStart: date(2026, 11, 20, 12),
                                           periodEnd: date(2026, 11, 20, 13), notBefore: date(2026, 11, 20, 13, 5))],
                           watermark: date(2026, 11, 20, 13))
        }
    }
    let sched = scheduler(db, FakeRunner(), kinds: [], planner: Hourly(db: db))
    _ = await sched.tick(signals(idle: 300))
    #expect(try SettingsStore(db).value(Date.self, forKey: JobPlanner.watermarkKey) == nil)
    #expect(try JobStore(db).job(kind: .hour, periodKey: "2026-11-20T12+0100") == nil)
    try await db.writer.write { d in try d.execute(sql: "DROP TRIGGER fail_hour") }
    _ = await sched.tick(signals(idle: 300))
    #expect(try JobStore(db).job(kind: .hour, periodKey: "2026-11-20T12+0100") != nil)
    #expect(try SettingsStore(db).value(Date.self, forKey: JobPlanner.watermarkKey) == date(2026, 11, 20, 13))
}

// MARK: - Final review #7: memory off plans no backlog

/// A week of hourly ticks with memory off (a new snapshot before each): no working-memory, hour or
/// other gated job piles up; only the time ledger and compaction are planned.
@Test func aWeekWithMemoryOffCreatesNoBacklogOfWorkingMemoryJobs() async throws {
    let db = try AppDatabase.inMemory()
    let clock = TestClock()
    let planner = JobPlanner(db: db, data: DatabasePlannerData(db: db), calendar: paris)
    let s = scheduler(db, FakeRunner(), planner: planner, clock: clock)
    for i in 0..<(7 * 24) {
        let now = t0.addingTimeInterval(Double(i) * 3_600)
        clock.advance(i == 0 ? 0 : 3_600)
        _ = try SnapshotStore(db).insert(Snapshot(capturedAt: now.addingTimeInterval(-60), app: "Notes", text: "note \(i)",
                                                  contentHash: "n\(i)", source: .ax))
        _ = await s.tick(signals(now: now, idle: 30, enabled: false))
    }
    let kinds = try await db.reader.read { try String.fetchAll($0, sql: "SELECT DISTINCT kind FROM jobs ORDER BY kind") }
    #expect(Set(kinds).isSubset(of: [JobKind.timeLedger.rawValue, JobKind.compaction.rawValue]))
    #expect(try await db.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM jobs WHERE kind = 'working_memory'") } == 0)
    // Where memory was turned off is kept (the horizon start: no watermark yet), and the planner
    // watermark kept advancing.
    #expect(try SettingsStore(db).value(Date.self, forKey: MemoryScheduler.heldWatermarkKey)
            == t0.addingTimeInterval(-JobPlanner.horizon))
    #expect(try SettingsStore(db).value(Date.self, forKey: JobPlanner.watermarkKey).map { $0 > t0 } == true)
}

/// A newer working-memory slot supersedes an older one still pending.
@Test func newerWorkingMemorySlotSkipsOlderPendingOnes() async throws {
    let db = try AppDatabase.inMemory()
    let older = try enqueue(db, .workingMemory, "2026-11-20T13+0100:30", start: date(2026, 11, 20, 13, 30),
                            notBefore: t0.addingTimeInterval(3_600))
    let planner = StubPlanner(specs: [JobSpec(kind: .workingMemory, periodKey: "2026-11-20T14+0100:00",
                                              periodStart: t0, periodEnd: t0.addingTimeInterval(600),
                                              notBefore: t0.addingTimeInterval(3_600))])
    _ = await scheduler(db, FakeRunner(), kinds: [], planner: planner).tick(signals(idle: 30))
    let skipped = try job(db, .workingMemory, older.periodKey)
    #expect(skipped.status == .skipped && skipped.lastError == "superseded")
    #expect(try job(db, .workingMemory, "2026-11-20T14+0100:00").status == .pending)
}

// MARK: - Final review #11, #16: cancelling a running job

/// #16: `suspend` while a job runs cancels it and returns only once it has ended; the job goes
/// back to pending without an attempt and nothing runs until `resume`.
@Test func suspendWhileAJobRunsCancelsAndAwaitsIt() async throws {
    let db = try AppDatabase.inMemory()
    try enqueue(db, .hour, "a", start: date(2026, 11, 20, 9))
    let started = AsyncStream<Void>.makeStream()
    let ended = Mutex(false), runs = Mutex(0)
    let runner = FakeRunner { _, _ in
        // Only the first run hangs; the run after `resume` returns at once.
        guard runs.withLock({ $0 += 1; return $0 }) == 1 else { return .done }
        started.continuation.yield()
        do { try await Task.sleep(for: .seconds(30)) } catch {
            ended.withLock { $0 = true }
            throw error
        }
        return .done
    }
    let s = scheduler(db, runner)
    let tick = Task { await s.tick(signals(idle: 300)) }
    var it = started.stream.makeAsyncIterator()
    _ = await it.next()
    await s.suspend()
    #expect(ended.withLock { $0 })                 // awaited: the runner had ended
    #expect(await s.runningKind() == nil)
    let a = try job(db, .hour, "a")
    #expect(a.status == .pending && a.attempts == 0)
    #expect(await tick.value.ran == [.hour])
    #expect(await s.tick(signals(idle: 300)).ran.isEmpty)
    await s.resume()
    #expect(await s.tick(signals(idle: 300)).ran == [.hour])
}

/// #11: a job still running when the Mac sleeps would time out on wake and count an attempt
/// (`timeoutCountsAsRetry`); the app's sleep cancel goes through `cancelCurrent`, so even a runner
/// that ignores cancellation until past its timeout comes back without an attempt.
@Test func cancelBeforeSleepNeverCountsTheTimeoutAsAnAttempt() async throws {
    let db = try AppDatabase.inMemory()
    try enqueue(db, .hour, "h", start: t0)
    let started = AsyncStream<Void>.makeStream()
    let runner = FakeRunner { _, _ in
        started.continuation.yield()
        // Ignores cancellation, outliving the 50 ms timeout (the Mac slept through it).
        await Task.detached { try? await Task.sleep(for: .milliseconds(300)) }.value
        return .done
    }
    let s = scheduler(db, runner, timeout: .milliseconds(50))
    let tick = Task { await s.tick(signals(idle: 300)) }
    var it = started.stream.makeAsyncIterator()
    _ = await it.next()
    await s.cancelCurrent()
    _ = await tick.value
    let j = try job(db, .hour, "h")
    #expect(j.status == .pending && j.attempts == 0 && j.lastError == nil)
}

/// Tests the decision functions `MemoryController` wires to notifications (no App test target).
@Test func lifecycleDecisionFunctionsCancelOnSignOutAndWarmOnlyWithMemoryAndModel() {
    #expect(MemoryLifecycle.cancelsOnAccountChange(wasReady: true, isReady: false))
    #expect(!MemoryLifecycle.cancelsOnAccountChange(wasReady: false, isReady: false))
    #expect(!MemoryLifecycle.cancelsOnAccountChange(wasReady: false, isReady: true))
    #expect(MemoryLifecycle.warmIndexDelay == .seconds(30))
    #expect(MemoryLifecycle.shouldWarmIndex(memoryEnabled: true, modelDownloaded: true))
    #expect(!MemoryLifecycle.shouldWarmIndex(memoryEnabled: false, modelDownloaded: true))
    #expect(!MemoryLifecycle.shouldWarmIndex(memoryEnabled: true, modelDownloaded: false))
}

/// #12: one status refresh at a time; a full one asked for during a light one runs after it.
@Test func statusRefreshesAreCoalesced() {
    var gate = StatusRefreshGate()
    var steps: [Bool] = []
    steps.append(gate.begin(full: false))   // starts
    steps.append(gate.begin(full: false))   // dropped
    steps.append(gate.begin(full: true))    // queued
    steps.append(gate.end())                // the queued full refresh starts now
    #expect(gate.inFlight)
    steps.append(gate.begin(full: true))    // queued again
    steps.append(gate.end())
    steps.append(gate.end())                // nothing queued: idle
    #expect(!gate.inFlight)
    steps.append(gate.begin(full: false))
    #expect(steps == [true, false, false, true, false, true, false, true])
}

/// Records the ranges the planner reads hour stats for.
private final class RecordingPlannerData: PlannerData, @unchecked Sendable {
    let base: DatabasePlannerData
    let froms = Mutex<[Date]>([])
    init(_ db: AppDatabase) { base = DatabasePlannerData(db: db) }
    func hourStats(from: Date, to: Date, calendar: Calendar) throws -> [HourStat] {
        froms.withLock { $0.append(from) }
        return try base.hourStats(from: from, to: to, calendar: calendar)
    }
    func newestSnapshotAt() throws -> Date? { try base.newestSnapshotAt() }
    func dirtyWikiPages(minMentions: Int) throws -> Int { try base.dirtyWikiPages(minMentions: minMentions) }
    func pendingEmbeddings() throws -> Int { try base.pendingEmbeddings() }
    func inlineOutputsSince(_ d: Date?) throws -> Int { try base.inlineOutputsSince(d) }
    func dayChroniclesSince(_ d: Date?) throws -> Int { try base.dayChroniclesSince(d) }
    func lastIdentityAt() throws -> Date? { try base.lastIdentityAt() }
    func dirtyChronicles() throws -> [(ChronicleLevel, String)] { try base.dirtyChronicles() }
}

/// Residual round #3: with memory off a tick never re-reads hours already passed (the watermark
/// advances); turning memory back on restores where it was turned off, so the hours missed while
/// off are planned.
@Test func memoryOffAdvancesTheWatermarkAndReEnablePlansTheMissedHours() async throws {
    let db = try AppDatabase.inMemory()
    let clock = TestClock()
    let data = RecordingPlannerData(db)
    let s = scheduler(db, FakeRunner(), kinds: [], planner: JobPlanner(db: db, data: data, calendar: paris), clock: clock)
    // On: the watermark reaches 13:00 (hours before it would be planned).
    try SettingsStore(db).setValue(date(2026, 11, 20, 13), forKey: JobPlanner.watermarkKey)
    for i in 0..<6 {
        let now = t0.addingTimeInterval(Double(i) * 3_600)
        if i > 0 { clock.advance(3_600) }
        _ = try SnapshotStore(db).insert(Snapshot(capturedAt: now.addingTimeInterval(-1_800), app: "Notes", text: "n\(i)",
                                                  contentHash: "n\(i)", source: .ax))
        try insertActivity(db, app: "Notes", from: now.addingTimeInterval(-1_800), seconds: 1_200)
        _ = await s.tick(signals(now: now, idle: 30, enabled: false))
    }
    let froms = data.froms.withLock { $0 }
    #expect(froms.count == 5, "\(froms)")   // no closed hour yet on the first tick
    #expect(zip(froms, froms.dropFirst()).allSatisfy { $0 < $1 })   // never re-reads passed hours
    #expect(try SettingsStore(db).value(Date.self, forKey: MemoryScheduler.heldWatermarkKey) == date(2026, 11, 20, 13))
    #expect(try JobStore(db).jobs(kind: .hour, overlapping: DateInterval(start: t0.addingTimeInterval(-86_400),
                                                                         end: t0.addingTimeInterval(86_400))).isEmpty)

    clock.advance(3_600)
    _ = await s.tick(signals(now: t0.addingTimeInterval(6 * 3_600), idle: 30, enabled: true))
    let planned = try JobStore(db).jobs(kind: .hour, overlapping: DateInterval(start: date(2026, 11, 20, 13),
                                                                             end: t0.addingTimeInterval(6 * 3_600)))
    #expect(planned.contains { ($0.periodStart ?? .distantFuture) <= t0 })   // the first hour missed while off
    #expect(try SettingsStore(db).value(Date.self, forKey: MemoryScheduler.heldWatermarkKey) == nil)
    #expect(data.froms.withLock { $0.last } == date(2026, 11, 20, 13))
}
