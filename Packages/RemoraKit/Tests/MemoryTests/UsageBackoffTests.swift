import Foundation
import Testing
import LLM
import Storage
@testable import Memory

@Test func backoffLadder() {
    var b = UsageBackoff()
    #expect(b.allowsProbe(at: t0))
    b.recordLimit(at: t0)
    #expect(b.step == 1 && b.until == t0 + 900)
    #expect(!b.allowsProbe(at: t0 + 899) && b.allowsProbe(at: t0 + 900))
    var waits: [TimeInterval] = [900]
    for _ in 0..<8 {
        b.recordLimit(at: t0)
        waits.append(b.until!.timeIntervalSince(t0))
    }
    #expect(waits == [900, 1_800, 3_600, 7_200, 14_400, 28_800, 43_200, 43_200, 43_200])
    b.recordSuccess()
    #expect(b == UsageBackoff())
}

@Test func usageLimitBacksOffWithoutBurningAttempts() async throws {
    let db = try AppDatabase.inMemory()
    for (i, key) in hourKeys(2).enumerated() { try enqueue(db, .hour, key, start: t0.addingTimeInterval(Double(i) * -3_600)) }
    let limited = Mutex2(true)
    let runner = FakeRunner { _, _ in
        if limited.value { throw LLMError.usageLimit }
        return .done
    }
    let scheduler = MemoryScheduler(db: db, runners: runners(runner), planner: nil, calendar: paris, now: { t0 })

    let first = await scheduler.tick(signals(idle: 300))
    #expect(first.ran == [.hour] && first.postponedForLimit)
    let hit = try #require(try JobStore(db).job(kind: .hour, periodKey: runner.calls[0].job.periodKey))
    #expect(hit.status == .pending && hit.attempts == 0 && hit.nextRunAt == t0 + 900 && hit.lastError == "usage_limit")
    #expect(MemorySettings(SettingsStore(db)).backoff() == UsageBackoff(step: 1, until: t0 + 900))
    // The other job was never attempted.
    #expect(try JobStore(db).counts() == [.pending: 2])

    // While backing off, no cloud job runs.
    let waiting = await scheduler.tick(signals(now: t0 + 60, idle: 300))
    #expect(waiting.ran.isEmpty && waiting.postponedForLimit)

    // At expiry exactly one probe runs (it made no cloud call, so the backoff stays).
    limited.value = false
    let probe = await scheduler.tick(signals(now: t0 + 901, idle: 300))
    #expect(probe.ran == [.hour])
    #expect(try JobStore(db).counts() == [.done: 1, .pending: 1])
    #expect(MemorySettings(SettingsStore(db)).backoff().step == 1)
}

@Test func completedCloudCallResetsBackoff() async throws {
    let db = try AppDatabase.inMemory()
    for (i, key) in hourKeys(3).enumerated() { try enqueue(db, .hour, key, start: t0.addingTimeInterval(Double(i) * -3_600)) }
    var b = UsageBackoff(); b.recordLimit(at: t0 - 7_200); b.recordLimit(at: t0 - 7_200)   // expired at t0 − 5,400
    try MemorySettings(SettingsStore(db)).setBackoff(b)
    let runner = FakeRunner { _, ctx in
        try seedUsage(db, tokens: 10, at: ctx.now)   // a completed SIWC call made by the job
        return .done
    }
    let scheduler = MemoryScheduler(db: db, runners: runners(runner), planner: nil, calendar: paris, now: { t0 })
    let report = await scheduler.tick(signals(idle: 300))
    #expect(report.ran == [.hour, .hour, .hour])
    #expect(MemorySettings(SettingsStore(db)).backoff() == UsageBackoff())
}

@Test func failedCloudCallDoesNotResetBackoff() async throws {
    let db = try AppDatabase.inMemory()
    try enqueue(db, .hour, "h", start: t0)
    var b = UsageBackoff(); b.recordLimit(at: t0 - 3_600)
    try MemorySettings(SettingsStore(db)).setBackoff(b)
    let runner = FakeRunner { _, ctx in
        try seedUsage(db, tokens: 10, at: ctx.now, status: .failed)
        try seedUsage(db, tokens: 10, at: ctx.now, backend: "on_device")
        return .done
    }
    let scheduler = MemoryScheduler(db: db, runners: runners(runner), planner: nil, calendar: paris, now: { t0 })
    _ = await scheduler.tick(signals(idle: 300))
    #expect(MemorySettings(SettingsStore(db)).backoff() == b)
}

/// F-21: only usage codes climb the ladder; a generic transient error is a retry.
@Test(arguments: [
    (LLMError.temporarilyUnavailable(code: "subscription_sharing_usage_unavailable"), true),
    (.temporarilyUnavailable(code: "subscription_sharing_user_unavailable"), true),
    (.temporarilyUnavailable(code: "server_error"), false),
    (.temporarilyUnavailable(code: "rate_limit_exceeded"), false),
    (.temporarilyUnavailable(code: nil), false),
    (.http(status: 503), false),
])
func onlyUsageCodesTriggerBackoff(error: LLMError, backsOff: Bool) async throws {
    let db = try AppDatabase.inMemory()
    try enqueue(db, .hour, "h", start: t0)
    let scheduler = MemoryScheduler(db: db, runners: runners(FakeRunner { _, _ in throw error }),
                                    planner: nil, calendar: paris, now: { t0 })
    let report = await scheduler.tick(signals(idle: 300))
    let job = try #require(try JobStore(db).job(kind: .hour, periodKey: "h"))
    #expect(report.postponedForLimit == backsOff)
    #expect(job.lastError == error.errorCode)
    if backsOff {
        #expect(job.attempts == 0 && job.nextRunAt == t0 + 900)
        #expect(MemorySettings(SettingsStore(db)).backoff().step == 1)
    } else {
        #expect(job.attempts == 1 && job.nextRunAt == t0 + 300)
        #expect(MemorySettings(SettingsStore(db)).backoff() == UsageBackoff())
    }
}

final class Mutex2<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ v: T) { stored = v }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
