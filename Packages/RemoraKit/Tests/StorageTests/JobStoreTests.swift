import Foundation
import GRDB
import Testing
@testable import Storage

private func spec(_ kind: JobKind, _ key: String, start: Date? = nil, hours: Double = 1,
                  notBefore: Date = memoryT0) -> JobSpec {
    JobSpec(kind: kind, periodKey: key, periodStart: start,
            periodEnd: start?.addingTimeInterval(hours * 3_600), notBefore: notBefore)
}

private func onlyJob(_ db: AppDatabase) throws -> Job {
    try #require(try db.reader.read { try Job.fetchAll($0) }.first)
}

@Test func enqueueIsIdempotentPerKindAndPeriod() throws {
    let db = try AppDatabase.inMemory()
    let store = JobStore(db)
    let s = spec(.hour, "2026-11-20T10+0100", start: memoryT0)
    #expect(try store.enqueue([s], now: memoryT0) == 1)
    #expect(try store.enqueue([s, s], now: memoryT0.addingTimeInterval(60)) == 0)
    #expect(try db.reader.read { try Job.fetchCount($0) } == 1)
    let job = try onlyJob(db)
    #expect(job.status == .pending && job.attempts == 0 && job.priority == JobKind.hour.priority)
    #expect(job.nextRunAt == memoryT0 && job.periodStart == memoryT0)
    // Another kind with the same key is another job.
    #expect(try store.enqueue([spec(.timeLedger, "2026-11-20T10+0100")], now: memoryT0) == 1)
}

@Test func nextDueOrdersByPriorityThenOldestPeriod() throws {
    let db = try AppDatabase.inMemory()
    let store = JobStore(db)
    let d18 = Date(timeIntervalSince1970: 1_795_000_000)
    _ = try store.enqueue([
        spec(.dayRollup, "2026-11-18", start: d18, hours: 24),
        spec(.hour, "2026-11-19T10+0100", start: d18.addingTimeInterval(90_000)),
        spec(.hour, "2026-11-18T09+0100", start: d18.addingTimeInterval(32_400)),
    ], now: memoryT0)
    let all = Set(JobKind.allCases)
    #expect(try store.nextDue(now: memoryT0, kinds: all)?.periodKey == "2026-11-18T09+0100")
    #expect(try store.nextDue(now: memoryT0, kinds: [.dayRollup])?.periodKey == "2026-11-18")
    #expect(try store.nextDue(now: memoryT0, kinds: [.identity]) == nil)
    #expect(try store.nextDue(now: memoryT0, kinds: []) == nil)
    // Not yet due, or not pending: never returned.
    #expect(try store.nextDue(now: memoryT0.addingTimeInterval(-1), kinds: all) == nil)
    let first = try #require(try store.nextDue(now: memoryT0, kinds: all))
    try store.markRunning(id: first.id!, now: memoryT0)
    #expect(try store.nextDue(now: memoryT0, kinds: all)?.periodKey == "2026-11-19T10+0100")
}

@Test func retryBacksOffThenFails() throws {
    let db = try AppDatabase.inMemory()
    let store = JobStore(db)
    _ = try store.enqueue([spec(.hour, "h")], now: memoryT0)
    let id = try onlyJob(db).id!
    var deltas: [TimeInterval] = []
    for attempt in 1...6 {
        try store.markRunning(id: id, now: memoryT0)
        try store.retry(id: id, error: "http_500", now: memoryT0)
        let job = try onlyJob(db)
        #expect(job.attempts == attempt && job.lastError == "http_500")
        if attempt < 6 {
            #expect(job.status == .pending)
            deltas.append(job.nextRunAt.timeIntervalSince(memoryT0))
        } else {
            #expect(job.status == .failed)
        }
    }
    #expect(deltas == [300, 600, 1_200, 2_400, 4_800])
    // The formula caps at 6 h.
    #expect(JobStore.retryDelay(afterAttempt: 10) == 21_600)
}

@Test func resetRunningAfterCrash() throws {
    let db = try AppDatabase.inMemory()
    let store = JobStore(db)
    _ = try store.enqueue([spec(.hour, "a"), spec(.hour, "b")], now: memoryT0)
    let a = try #require(try store.job(kind: .hour, periodKey: "a"))
    try store.markRunning(id: a.id!, now: memoryT0)
    #expect(try store.status(kind: .hour, periodKey: "a") == .running)
    let later = memoryT0.addingTimeInterval(600)
    #expect(try store.resetRunning(now: later) == 1)
    let reset = try #require(try store.job(kind: .hour, periodKey: "a"))
    #expect(reset.status == .pending && reset.attempts == 0 && reset.updatedAt == later)
    #expect(try store.counts() == [.pending: 2])
}

@Test func completePostponeRequeueAndCounts() throws {
    let db = try AppDatabase.inMemory()
    let store = JobStore(db)
    _ = try store.enqueue([spec(.hour, "a"), spec(.hour, "b"), spec(.hour, "c")], now: memoryT0)
    let a = try #require(try store.job(kind: .hour, periodKey: "a")).id!
    let b = try #require(try store.job(kind: .hour, periodKey: "b")).id!
    try store.complete(id: a, status: .done, now: memoryT0)
    try store.complete(id: b, status: .skipped, reason: "no_evidence", now: memoryT0)
    #expect(try store.counts() == [.done: 1, .skipped: 1, .pending: 1])
    #expect(try store.job(kind: .hour, periodKey: "b")?.lastError == "no_evidence")

    // Postpone never counts an attempt.
    let c = try #require(try store.job(kind: .hour, periodKey: "c")).id!
    try store.markRunning(id: c, now: memoryT0)
    try store.postpone(id: c, until: memoryT0.addingTimeInterval(900), reason: "usage_limit")
    let postponed = try #require(try store.job(kind: .hour, periodKey: "c"))
    #expect(postponed.status == .pending && postponed.attempts == 0)
    #expect(postponed.nextRunAt == memoryT0.addingTimeInterval(900) && postponed.lastError == "usage_limit")

    // Requeue: any status back to pending, attempts 0, due now. Unknown keys are a no-op.
    try store.retry(id: a, error: "x", now: memoryT0)
    let now = memoryT0.addingTimeInterval(7_200)
    try store.requeue(kind: .hour, periodKey: "a", now: now)
    try store.requeue(kind: .hour, periodKey: "missing", now: now)
    let requeued = try #require(try store.job(kind: .hour, periodKey: "a"))
    #expect(requeued.status == .pending && requeued.attempts == 0 && requeued.nextRunAt == now)
    #expect(requeued.lastError == nil)
    #expect(try store.status(kind: .hour, periodKey: "missing") == nil)
    #expect(try db.reader.read { try Job.fetchCount($0) } == 3)
}

/// F-5: hour jobs are keyed by merged span, so the planner asks by overlap.
@Test func jobsOverlappingIntervalMatchesSpans() throws {
    let db = try AppDatabase.inMemory()
    let store = JobStore(db)
    let day = DateInterval(start: memoryT0, duration: 86_400)
    _ = try store.enqueue([
        spec(.hour, "before", start: memoryT0.addingTimeInterval(-3_600)),                 // ends at day start
        spec(.hour, "span", start: memoryT0.addingTimeInterval(-1_800), hours: 2),         // straddles the start
        spec(.hour, "inside", start: memoryT0.addingTimeInterval(36_000)),
        spec(.hour, "after", start: memoryT0.addingTimeInterval(86_400)),                  // starts at day end
        spec(.timeLedger, "inside", start: memoryT0.addingTimeInterval(36_000)),
        spec(.hour, "no-period"),
    ], now: memoryT0)
    let keys = try store.jobs(kind: .hour, overlapping: day).map(\.periodKey)
    #expect(keys == ["span", "inside"])
}

/// F-6: runners write job rows inside `DataGeneration.write`, so every mutating method has
/// an `in:` form that uses the given connection.
@Test func storeOverloadsRunInsideGenerationWrite() throws {
    let db = try AppDatabase.inMemory()
    let store = JobStore(db)
    let now = memoryT0.addingTimeInterval(60)
    try DataGeneration.write(db, expected: 0) { d in
        #expect(try store.enqueue([spec(.dayRollup, "2026-11-19"), spec(.hour, "h")], now: memoryT0, in: d) == 2)
        let h = try #require(try store.job(kind: .hour, periodKey: "h", in: d)).id!
        try store.markRunning(id: h, now: now, in: d)
        try store.complete(id: h, status: .done, now: now, in: d)
        try store.requeue(kind: .dayRollup, periodKey: "2026-11-19", now: now, in: d)
        let r = try #require(try store.job(kind: .dayRollup, periodKey: "2026-11-19", in: d)).id!
        try store.retry(id: r, error: "timeout", now: now, in: d)
        try store.postpone(id: r, until: now.addingTimeInterval(900), in: d)
        #expect(try store.nextDue(now: now, kinds: [.dayRollup], in: d) == nil)
        #expect(try store.resetRunning(now: now, in: d) == 0)
    }
    #expect(try store.counts() == [.done: 1, .pending: 1])
    #expect(try store.job(kind: .dayRollup, periodKey: "2026-11-19")?.attempts == 1)
}

/// The scheduler records a run's result only while the row is still `running`, so a requeue
/// made during the run (planner, "Run now") is not overwritten.
@Test func guardedWritesOnlyTouchRunningRows() throws {
    let db = try AppDatabase.inMemory()
    let store = JobStore(db)
    _ = try store.enqueue([spec(.hour, "a")], now: memoryT0)
    let id = try #require(try store.job(kind: .hour, periodKey: "a")).id!
    let later = memoryT0.addingTimeInterval(600)
    // Pending (requeued mid-run): every guarded write is a no-op.
    try store.complete(id: id, status: .done, now: later, ifRunning: true)
    try store.retry(id: id, error: "http_500", now: later, ifRunning: true)
    try store.postpone(id: id, until: later.addingTimeInterval(900), reason: "usage_limit", ifRunning: true)
    var job = try #require(try store.job(kind: .hour, periodKey: "a"))
    #expect(job.status == .pending && job.attempts == 0 && job.nextRunAt == memoryT0 && job.lastError == nil)
    // Running: each applies.
    try store.markRunning(id: id, now: later)
    try store.retry(id: id, error: "http_500", now: later, ifRunning: true)
    job = try #require(try store.job(kind: .hour, periodKey: "a"))
    #expect(job.status == .pending && job.attempts == 1)
    try store.markRunning(id: id, now: later)
    try store.postpone(id: id, until: later.addingTimeInterval(900), reason: "usage_limit", ifRunning: true)
    #expect(try store.job(kind: .hour, periodKey: "a")?.nextRunAt == later.addingTimeInterval(900))
    try store.markRunning(id: id, now: later)
    try store.complete(id: id, status: .done, now: later, ifRunning: true)
    #expect(try store.status(kind: .hour, periodKey: "a") == .done)
}

@Test func guardedRequeueTouchesOnlyListedStatuses() throws {
    let db = try AppDatabase.inMemory()
    let store = JobStore(db)
    _ = try store.enqueue([spec(.dayRollup, "2026-11-20")], now: memoryT0)
    let id = try #require(try onlyJob(db).id)
    let later = memoryT0.addingTimeInterval(600)
    let finished: Set<JobStatus> = [.done, .skipped]

    try store.markRunning(id: id, now: memoryT0)
    #expect(try db.writer.write { try store.requeue(kind: .dayRollup, periodKey: "2026-11-20", now: later,
                                                    ifStatusIn: finished, in: $0) } == false)
    #expect(try onlyJob(db).status == .running)

    try store.complete(id: id, status: .failed, reason: "invalid_output", now: memoryT0)
    #expect(try db.writer.write { try store.requeue(kind: .dayRollup, periodKey: "2026-11-20", now: later,
                                                    ifStatusIn: finished, in: $0) } == false)
    #expect(try onlyJob(db).status == .failed)

    try store.complete(id: id, status: .skipped, reason: "no_children", now: memoryT0)
    #expect(try db.writer.write { try store.requeue(kind: .dayRollup, periodKey: "2026-11-20", now: later,
                                                    ifStatusIn: finished, in: $0) } == true)
    let job = try onlyJob(db)
    #expect(job.status == .pending && job.nextRunAt == later && job.lastError == nil && job.attempts == 0)
}
