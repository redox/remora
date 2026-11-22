import Foundation
import LLM
import Storage
import Synchronization
import Testing
@testable import Memory

// F-46: the app's signal mapping and the idle-return guard are pure and tested here.

private func make(_ account: SignInState = .signedIn(email: nil, planUsageEnabled: true),
                  onDevice: OnDeviceAvailability = .available, idle: TimeInterval = 300, power: Bool = true,
                  lowPower: Bool = false, enabled: Bool = true) -> SchedulerSignals {
    SchedulerSignals.make(account: account, onDevice: onDevice, idle: idle, power: power, lowPower: lowPower,
                          memoryEnabled: enabled, now: t0)
}

@Test func accountReadyOnlyWhenSignedInWithPlanUsage() {
    #expect(make(.signedIn(email: "a@b.c", planUsageEnabled: true)).accountReady)
    #expect(make(.signedIn(email: nil, planUsageEnabled: true)).accountReady)
    #expect(!make(.signedIn(email: "a@b.c", planUsageEnabled: false)).accountReady)
    #expect(!make(.signedOut).accountReady)
    #expect(!make(.needsSignIn).accountReady)
    #expect(!make(.unavailable).accountReady)
}

@Test func onDeviceAvailableOnlyWhenAvailable() {
    #expect(make(onDevice: .available).onDeviceAvailable)
    #expect(!make(onDevice: .unavailable("model_not_ready")).onDeviceAvailable)
}

@Test func lowPowerModeCountsAsNotOnPower() {
    let plugged = make(power: true, lowPower: false)
    #expect(plugged.onPower && !plugged.lowPower)
    let lowPowerPlugged = make(power: true, lowPower: true)
    #expect(!lowPowerPlugged.onPower && lowPowerPlugged.lowPower)
    #expect(!make(power: false, lowPower: false).onPower)
    // So idle-on-power jobs never run in Low Power Mode, even plugged in.
    #expect(!RunCondition.idleOnPower.holds(make(idle: 600, power: true, lowPower: true)))
    #expect(RunCondition.idleOnPower.holds(make(idle: 600, power: true, lowPower: false)))
}

@Test func signalsCarryIdleTimeEnabledAndNow() {
    let s = make(idle: 42, enabled: false)
    #expect(s.idleSeconds == 42 && !s.memoryEnabled && s.now == t0)
    // A negative or non-finite idle reading (no input source) counts as active, never as idle.
    #expect(make(idle: -1).idleSeconds == 0)
    #expect(make(idle: .nan).idleSeconds == 0)
    #expect(make(idle: .infinity).idleSeconds == 0)
}

@Test func idleReturnCancelsOnlyIdleGatedWorkOfAnIdleTick() {
    // The tick was planned while idle and the user is back.
    #expect(IdleReturn.shouldCancel(tickIdleSeconds: 300, nowIdleSeconds: 2, runningKind: .identity))
    #expect(IdleReturn.shouldCancel(tickIdleSeconds: 300, nowIdleSeconds: 2, runningKind: .embeddings))
    #expect(IdleReturn.shouldCancel(tickIdleSeconds: 300, nowIdleSeconds: 2, runningKind: .compaction))
    // Between jobs: stop the tick before it picks another job with stale signals.
    #expect(IdleReturn.shouldCancel(tickIdleSeconds: 300, nowIdleSeconds: 2, runningKind: nil))
    // An anytime job is left to finish (its result is still valid).
    #expect(!IdleReturn.shouldCancel(tickIdleSeconds: 300, nowIdleSeconds: 2, runningKind: .hour))
    // Still idle: nothing to do.
    #expect(!IdleReturn.shouldCancel(tickIdleSeconds: 300, nowIdleSeconds: 330, runningKind: .identity))
    // The tick was planned while active: no idle-gated job could have been picked.
    #expect(!IdleReturn.shouldCancel(tickIdleSeconds: 30, nowIdleSeconds: 2, runningKind: .identity))
}

@Test func schedulerReportsTheRunningKind() async throws {
    let db = try AppDatabase.inMemory()
    let started = Mutex<CheckedContinuation<Void, Never>?>(nil)
    let release = Mutex<CheckedContinuation<Void, Never>?>(nil)
    let runner = FakeRunner { _, _ in
        await withCheckedContinuation { c in
            release.withLock { $0 = c }
            started.withLock { $0?.resume(); $0 = nil }
        }
        return .done
    }
    let scheduler = MemoryScheduler(db: db, runners: runners(runner, for: [.identity]), planner: nil, calendar: paris,
                                    now: { t0 })
    try enqueue(db, .identity, "2026-W47")
    #expect(await scheduler.runningKind() == nil)
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        started.withLock { $0 = c }
        Task { _ = await scheduler.tick(signals(idle: 300)) }
    }
    #expect(await scheduler.runningKind() == .identity)
    release.withLock { $0?.resume(); $0 = nil }
    await scheduler.cancelCurrent()
    #expect(await scheduler.runningKind() == nil)
}

@Test func productionCalendarIsISOInTheLocalTimeZone() {
    let c = PeriodKey.localCalendar
    #expect(c.identifier == .iso8601)
    // Auto-updating (final review #10): a time-zone change is followed without a relaunch.
    #expect(c.timeZone == TimeZone.autoupdatingCurrent)
    #expect(c.timeZone.identifier == TimeZone.current.identifier)
    #expect(c.firstWeekday == 2 && c.minimumDaysInFirstWeek == 4)
}

@Test func suspendedSchedulerRunsNothingUntilResumed() async throws {
    let db = try AppDatabase.inMemory()
    let runner = FakeRunner()
    let scheduler = MemoryScheduler(db: db, runners: runners(runner, for: [.hour, .compaction]), planner: nil,
                                    calendar: paris, now: { t0 })
    try enqueue(db, .hour, "2026-11-20T12+0100", start: date(2026, 11, 20, 12))
    await scheduler.suspend()
    #expect(await scheduler.tick(signals()).ran.isEmpty)
    #expect(await scheduler.runNow(kind: .compaction, periodKey: "2026-11-20", signals: signals()).ran.isEmpty)
    #expect(runner.calls.isEmpty)
    // Nothing was enqueued while suspended (a delete-all may be running).
    #expect(try JobStore(db).job(kind: .compaction, periodKey: "2026-11-20") == nil)
    await scheduler.resume()
    #expect(await scheduler.tick(signals()).ran == [.hour])
}
