import Foundation
import LLM
import os
import Storage

/// The state a tick decides with. Built by the app (Task 14) from the system and account.
public struct SchedulerSignals: Sendable, Equatable {
    public var now: Date
    public var idleSeconds: TimeInterval
    public var onPower: Bool
    public var lowPower: Bool
    /// Signed in with plan usage enabled.
    public var accountReady: Bool
    public var onDeviceAvailable: Bool
    public var memoryEnabled: Bool

    public init(now: Date, idleSeconds: TimeInterval, onPower: Bool, lowPower: Bool, accountReady: Bool,
                onDeviceAvailable: Bool, memoryEnabled: Bool) {
        self.now = now; self.idleSeconds = idleSeconds; self.onPower = onPower; self.lowPower = lowPower
        self.accountReady = accountReady; self.onDeviceAvailable = onDeviceAvailable
        self.memoryEnabled = memoryEnabled
    }
}

public struct TickReport: Sendable, Equatable {
    /// Kinds whose runner was called, in order (whatever the outcome).
    public var ran: [JobKind]
    /// A usage limit hit this tick, or due cloud jobs are waiting for the backoff.
    public var postponedForLimit: Bool

    public init(ran: [JobKind] = [], postponedForLimit: Bool = false) {
        self.ran = ran; self.postponedForLimit = postponedForLimit
    }
}

/// Runs background memory jobs one at a time.
///
/// A tick plans (enqueues the planner's specs), then repeatedly picks the next due job among the
/// kinds whose run condition holds and that the gate lets run (memory on, account, usage backoff),
/// runs it with the data generation read before it started, and records the result. Up to 1 job
/// per tick while the user is active (idle < 60 s), up to 20 when idle. Every write after a run
/// is generation-checked, so a job straddling "Delete all data" leaves nothing behind.
/// Overlapping ticks are no-ops.
public actor MemoryScheduler {
    static let activeIdleThreshold: TimeInterval = 60
    static let activeJobsPerTick = 1
    static let idleJobsPerTick = 20
    /// Account and plan states (not signed in, not eligible, …) retry after this, no attempt.
    static let accountRetryDelay: TimeInterval = 900

    private static let log = Logger(subsystem: "dev.remora", category: "memory")

    private let db: AppDatabase
    private let runners: [JobKind: any JobRunner]
    private let planner: (any JobPlanning)?
    private let calendar: Calendar
    /// Overrides every kind's `JobKind.timeout` when set (tests).
    private let jobTimeout: Duration?
    private let store: JobStore
    private let settings: MemorySettings
    private let clock: @Sendable () -> Date

    private var busy = false
    private var stopRequested = false
    private var suspended = false
    private var currentJob: Task<JobOutcome, any Error>?
    private var currentKind: JobKind?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    /// `now` is the clock that times each job within a tick (see `runJobs`).
    public init(db: AppDatabase, runners: [JobKind: any JobRunner], planner: (any JobPlanning)?,
                calendar: Calendar, jobTimeout: Duration? = nil,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.db = db; self.runners = runners; self.planner = planner; self.calendar = calendar
        self.jobTimeout = jobTimeout; clock = now
        store = JobStore(db)
        settings = MemorySettings(SettingsStore(db))
    }

    /// At app launch: jobs left `running` go back to `pending`.
    public func launch(now: Date) throws {
        let reset = try store.resetRunning(now: now)
        if reset > 0 { Self.log.info("reset \(reset, privacy: .public) running jobs at launch") }
    }

    public func tick(_ s: SchedulerSignals) async -> TickReport {
        guard !busy, !suspended else { return TickReport() }
        busy = true
        defer { finishRun() }
        plan(s)
        let limit = s.idleSeconds < Self.activeIdleThreshold ? Self.activeJobsPerTick : Self.idleJobsPerTick
        return await runJobs(s, limit: limit, only: nil)
    }

    /// "Run now" (F-9): enqueues or requeues `(kind, periodKey)` and runs that one job, ignoring its
    /// run condition but never the usage backoff or memory being off. Waits for a
    /// running tick to finish first.
    public func runNow(kind: JobKind, periodKey: String, signals s: SchedulerSignals) async -> TickReport {
        while busy { await waitUntilIdle() }
        guard !suspended else { return TickReport() }
        busy = true
        defer { finishRun() }
        do {
            // Generation-checked: a delete-all in between must not bring the row back.
            let store = store
            try DataGeneration.write(db, expected: try DataGeneration.current(db)) { d in
                try store.enqueue([JobSpec(kind: kind, periodKey: periodKey, notBefore: s.now)], now: s.now, in: d)
                try store.requeue(kind: kind, periodKey: periodKey, now: s.now, in: d)
            }
        } catch {
            Self.log.error("run now \(kind.rawValue, privacy: .public) failed: \(Self.code(for: error), privacy: .public)")
            return TickReport()
        }
        return await runJobs(s, limit: 1, only: (kind, periodKey))
    }

    /// Before "Delete all data": from now on `tick` and `runNow` do nothing (no planning, no
    /// enqueue, no job) until `resume`; the running job is cancelled and awaited.
    public func suspend() async {
        suspended = true
        await cancelCurrent()
    }

    public func resume() { suspended = false }

    /// The kind of the job running now; nil between jobs and when no tick runs.
    public func runningKind() -> JobKind? { currentKind }

    /// Cancels the running job (it goes back to `pending` without an attempt), stops the tick and
    /// waits until it has ended. Used before "Delete all data".
    public func cancelCurrent() async {
        guard busy else { return }
        stopRequested = true
        currentJob?.cancel()
        while busy { await waitUntilIdle() }
    }

    // MARK: - Tick

    /// Commits the planner's specs, watermark and requeues in one transaction under the generation read before planning: a delete-all that
    /// lands while planning drops them.
    private func plan(_ s: SchedulerSignals) {
        guard let planner else { return }
        do {
            let generation = try DataGeneration.current(db)
            try syncHeldWatermark(s, generation: generation)
            let plan = Self.gated(try planner.plan(s), memoryEnabled: s.memoryEnabled)
            let store = store
            let inserted = try DataGeneration.write(db, expected: generation) { d in
                let inserted = try store.enqueue(plan.specs, now: s.now, in: d)
                // A newer working-memory slot replaces any older one still waiting.
                for spec in plan.specs where spec.kind == .workingMemory {
                    if let start = spec.periodStart {
                        try store.skipPending(kind: .workingMemory, startingBefore: start, now: s.now, in: d)
                    }
                }
                if let watermark = plan.watermark {
                    try SettingsStore(db).setValue(watermark, forKey: JobPlanner.watermarkKey, in: d)
                }
                for ref in plan.requeues {
                    if let statuses = ref.ifStatusIn {
                        try store.requeue(kind: ref.kind, periodKey: ref.periodKey, now: s.now, ifStatusIn: statuses, in: d)
                    } else {
                        try store.requeue(kind: ref.kind, periodKey: ref.periodKey, now: s.now, in: d)
                    }
                }
                return inserted
            }
            if inserted > 0 { Self.log.info("planned \(inserted, privacy: .public) jobs") }
        } catch is DataGeneration.Stale {
            Self.log.info("planned jobs discarded: data was deleted")
        } catch {
            Self.log.error("planning failed: \(Self.code(for: error), privacy: .public)")
        }
    }

    /// With memory off, only kinds the gate still runs are planned (`time_ledger`, `compaction`):
    /// no backlog of working-memory, hour or other jobs builds up while nothing may run them. The
    /// watermark still advances (a tick never re-reads hours already passed); `syncHeldWatermark`
    /// keeps where memory was turned off.
    static func gated(_ plan: JobPlan, memoryEnabled: Bool) -> JobPlan {
        guard !memoryEnabled else { return plan }
        let specs = plan.specs.filter {
            SchedulerGate.decide($0.kind, memoryEnabled: false, accountReady: true, backoffAllows: true)
                != .deny(.disabled)
        }
        return JobPlan(specs: specs, watermark: plan.watermark, requeues: plan.requeues)
    }

    /// Where the hour watermark stood when memory was turned off.
    public static let heldWatermarkKey = "memory.plannerWatermarkHeld"

    /// On the first tick with memory off, saves the watermark (`heldWatermarkKey`; the horizon
    /// start when none); on the first tick with memory back on, restores it, clamped to the
    /// planner's 30-day horizon, so the hours missed while off are planned. Every other tick only
    /// reads one setting.
    private func syncHeldWatermark(_ s: SchedulerSignals, generation: Int) throws {
        let settings = SettingsStore(db)
        let held = try settings.value(Date.self, forKey: Self.heldWatermarkKey)
        guard s.memoryEnabled == (held != nil) else { return }
        let horizonStart = s.now.addingTimeInterval(-JobPlanner.horizon)
        try DataGeneration.write(db, expected: generation) { d in
            if let held = try settings.value(Date.self, forKey: Self.heldWatermarkKey, in: d) {
                guard s.memoryEnabled else { return }
                try settings.setValue(max(held, horizonStart), forKey: JobPlanner.watermarkKey, in: d)
                try settings.setValue(Date?.none, forKey: Self.heldWatermarkKey, in: d)
            } else if !s.memoryEnabled {
                let current = try settings.value(Date.self, forKey: JobPlanner.watermarkKey, in: d) ?? horizonStart
                try settings.setValue(current, forKey: Self.heldWatermarkKey, in: d)
            }
        }
    }

    private enum Pick {
        case run(Job, cloudAllowed: Bool)
        case none
    }

    /// Job times (picking, `markRunning`, `JobContext.now`, backoff checks) come
    /// from the clock when the job starts; retry, postpone and backoff times from the clock when it
    /// ends. The clock is anchored to `signals.now`: time = `s.now` + clock time elapsed since the
    /// tick began, so a long tick does not compress delays and the tick's own time base is kept.
    private func runJobs(_ s: SchedulerSignals, limit: Int, only: (kind: JobKind, periodKey: String)?) async -> TickReport {
        let base = clock()
        let clock = clock
        func currentTime() -> Date { s.now.addingTimeInterval(clock().timeIntervalSince(base)) }
        var report = TickReport()
        var backoff = settings.backoff()
        var probeSpent = false
        let language = settings.language()

        func gate(backoffAllows: Bool) -> (JobKind) -> SchedulerGate.Decision {
            { SchedulerGate.decide($0, memoryEnabled: s.memoryEnabled, accountReady: s.accountReady,
                                   backoffAllows: backoffAllows) }
        }

        while report.ran.count < limit, !stopRequested {
            let now = currentTime()
            let generation: Int
            do { generation = try DataGeneration.current(db) } catch {
                Self.log.error("data generation unreadable; no job runs")
                break
            }

            let decide = gate(backoffAllows: !probeSpent && backoff.allowsProbe(at: now))
            let pick: Pick
            do {
                if let only {
                    pick = try pickRequested(only.kind, only.periodKey, now: now, gate: decide, report: &report)
                } else {
                    pick = try pickNext(s, now: now, gate: decide)
                }
            } catch {
                Self.log.error("job queue unreadable: \(Self.code(for: error), privacy: .public)")
                break
            }
            guard case .run(let job, let cloudAllowed) = pick, let id = job.id, let runner = runners[job.kind] else {
                break
            }

            do { try store.markRunning(id: id, now: now) } catch {
                Self.log.error("job queue unwritable: \(Self.code(for: error), privacy: .public)")
                break
            }
            let probing = cloudAllowed && backoff.step > 0
            let context = JobContext(now: now, calendar: calendar, generation: generation,
                                     cloudAllowed: cloudAllowed, language: language)
            let started = ContinuousClock.now
            let result = await execute(runner, job, context)
            report.ran.append(job.kind)
            let finished = currentTime()

            let disposition = Self.disposition(for: result, cancelRequested: stopRequested)
            Self.log.info("""
                job \(job.kind.rawValue, privacy: .public) \(job.periodKey, privacy: .public) \
                \(disposition.logLabel, privacy: .public) in \((ContinuousClock.now - started).milliseconds, privacy: .public) ms
                """)
            if disposition.isUsageLimit { report.postponedForLimit = true }

            do {
                backoff = try record(disposition, job: job, id: id, generation: generation, backoff: backoff,
                                     startedAt: now, now: finished)
            } catch is DataGeneration.Stale {
                Self.log.info("job \(job.kind.rawValue, privacy: .public) result discarded: data was deleted")
                break
            } catch {
                Self.log.error("job result unrecorded: \(Self.code(for: error), privacy: .public)")
                // Best effort: do not leave the row `running` until the next launch. Not
                // generation-checked; it only updates an existing running row by id.
                try? store.postpone(id: id, until: job.nextRunAt, ifRunning: true)
                break
            }
            if disposition.stopsTick { break }
            // One probe per expiry: until a cloud call completes, no other cloud job runs this tick.
            if probing, backoff.step > 0 { probeSpent = true }
        }

        if only == nil, !stopRequested {
            let now = currentTime()
            addHeldFlags(&report, s, now: now, gate: gate(backoffAllows: !probeSpent && backoff.allowsProbe(at: now)))
        }
        return report
    }

    /// The next due job among the kinds the gate lets run and whose run condition holds. Compaction
    /// 24 h overdue runs on plain idle (no power needed).
    private func pickNext(_ s: SchedulerSignals, now: Date, gate: (JobKind) -> SchedulerGate.Decision) throws -> Pick {
        var cloud: [JobKind: Bool] = [:]
        for kind in runners.keys {
            if case .run(let allowed) = gate(kind) { cloud[kind] = allowed }
        }
        let ready = Set(cloud.keys.filter { $0.runCondition.holds(s) })
        var job = try store.nextDue(now: now, kinds: ready)
        if job == nil, cloud[.compaction] != nil, !ready.contains(.compaction),
           RunCondition.idle(RunCondition.idleOnPowerSeconds).holds(s) {
            job = try store.nextDue(now: now.addingTimeInterval(-JobKind.compactionOverdue), kinds: [.compaction])
        }
        guard let job, let allowed = cloud[job.kind] else { return .none }
        return .run(job, cloudAllowed: allowed)
    }

    /// The requested job, if pending and due, ignoring its run condition (F-9).
    private func pickRequested(_ kind: JobKind, _ periodKey: String, now: Date,
                               gate: (JobKind) -> SchedulerGate.Decision, report: inout TickReport) throws -> Pick {
        guard runners[kind] != nil, let job = try store.job(kind: kind, periodKey: periodKey),
              job.status == .pending, job.nextRunAt <= now else { return .none }
        switch gate(kind) {
        case .run(let allowed): return .run(job, cloudAllowed: allowed)
        case .deny(.backoff): report.postponedForLimit = true
        case .deny: break
        }
        return .none
    }

    /// Flags due jobs that the backoff (not their run condition) kept waiting.
    private func addHeldFlags(_ report: inout TickReport, _ s: SchedulerSignals, now: Date,
                              gate: (JobKind) -> SchedulerGate.Decision) {
        var limitHeld: Set<JobKind> = []
        for kind in runners.keys where kind.runCondition.holds(s) {
            switch gate(kind) {
            case .deny(.backoff): limitHeld.insert(kind)
            default: break
            }
        }
        if (try? store.nextDue(now: now, kinds: limitHeld)) != nil { report.postponedForLimit = true }
    }

    // MARK: - Running one job

    private struct JobTimeout: Error {}

    /// How long a job of `kind` may run: `JobKind.timeout` (production), or the `jobTimeout`
    /// override when set (tests).
    nonisolated func timeout(for kind: JobKind) -> Duration { jobTimeout ?? kind.timeout }

    /// Runs the job in a child task raced against its kind's timeout (`JobKind.timeout`, or
    /// `jobTimeout` when set); `cancelCurrent` cancels it. A
    /// runner that ignores cancellation still holds the tick until it returns.
    private func execute(_ runner: any JobRunner, _ job: Job, _ context: JobContext) async -> Result<JobOutcome, any Error> {
        let timeout = timeout(for: job.kind)
        let task = Task<JobOutcome, any Error> {
            try await withThrowingTaskGroup(of: JobOutcome?.self) { group in
                group.addTask { try await runner.run(job, context: context) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    return nil
                }
                defer { group.cancelAll() }
                guard let first = try await group.next(), let outcome = first else { throw JobTimeout() }
                return outcome
            }
        }
        currentJob = task
        currentKind = job.kind
        defer { currentJob = nil; currentKind = nil }
        return await task.result
    }

    /// What to do with a job after its runner returned or threw.
    enum Disposition: Equatable {
        case complete(JobStatus, reason: String?)
        /// Usage limit (F-21): climb the backoff ladder, postpone without an attempt, stop the tick.
        case usageLimit(code: String)
        /// Account or plan state (F-7): retry later without an attempt, stop the tick.
        case postpone(TimeInterval, code: String)
        /// Cancelled: back to pending as it was, stop the tick.
        case requeue
        /// Counts an attempt; `code` is an error code only (F-60).
        case retry(code: String)
        /// The data generation changed: write nothing, stop the tick.
        case stale

        var stopsTick: Bool {
            switch self {
            case .complete, .retry: false
            case .usageLimit, .postpone, .requeue, .stale: true
            }
        }

        var isUsageLimit: Bool {
            if case .usageLimit = self { return true }
            return false
        }

        var logLabel: String {
            switch self {
            case .complete(let status, let reason): reason.map { "\(status.rawValue) (\($0))" } ?? status.rawValue
            case .usageLimit(let code): "usage limit (\(code))"
            case .postpone(_, let code): "postponed (\(code))"
            case .requeue: "cancelled"
            case .retry(let code): "retry (\(code))"
            case .stale: "stale"
            }
        }
    }

    static func disposition(for result: Result<JobOutcome, any Error>, cancelRequested: Bool) -> Disposition {
        let error: any Error
        switch result {
        case .success(.done): return .complete(.done, reason: nil)
        case .success(.skipped(let reason)): return .complete(.skipped, reason: reason)
        case .failure(let e): error = e
        }
        if error is DataGeneration.Stale { return .stale }
        if cancelRequested || error is CancellationError || (error as? LLMError) == .cancelled { return .requeue }
        if error is JobTimeout { return .retry(code: "timeout") }
        guard let llm = error as? LLMError else { return .retry(code: code(for: error)) }
        switch llm {
        case .usageLimit:
            return .usageLimit(code: llm.errorCode ?? "usage_limit")
        case .temporarilyUnavailable(let code?) where isUsageCode(code):
            return .usageLimit(code: code)
        case .notSignedIn, .needsSignIn, .planUsageDisabled, .notEligible, .unauthorized, .forbidden, .configuration:
            return .postpone(accountRetryDelay, code: llm.errorCode ?? "account")
        case .onDeviceUnavailable:
            return .complete(.skipped, reason: "on_device_unavailable")
        default:
            return .retry(code: code(for: llm))
        }
    }

    /// `subscription_sharing_usage_*` and `…user_unavailable`: the account's usage is spent.
    static func isUsageCode(_ code: String) -> Bool {
        code.hasPrefix("subscription_sharing_usage_") || code.hasSuffix("user_unavailable")
    }

    /// An error code for logs and `last_error`: never an error's description (F-60).
    static func code(for error: any Error) -> String {
        if let llm = error as? LLMError { return llm.errorCode ?? "llm_error" }
        if let coded = error as? CodedError { return coded.code }
        return String(describing: type(of: error))
    }

    /// Writes the job's new state (and the backoff) in one generation-checked transaction;
    /// returns the backoff now in force. Throws `DataGeneration.Stale` after a delete-all. Job
    /// rows change only while still `running`, so a requeue made during the run wins.
    private func record(_ disposition: Disposition, job: Job, id: Int64, generation: Int, backoff: UsageBackoff,
                        startedAt: Date, now: Date) throws -> UsageBackoff {
        if disposition == .stale { throw DataGeneration.Stale() }
        let store = store, settings = settings
        return try DataGeneration.write(db, expected: generation) { d in
            var next = backoff
            switch disposition {
            case .complete(let status, let reason):
                try store.complete(id: id, status: status, reason: reason, now: now, ifRunning: true, in: d)
            case .usageLimit(let code):
                next.recordLimit(at: now)
                try store.postpone(id: id, until: next.until ?? now, reason: code, ifRunning: true, in: d)
            case .postpone(let delay, let code):
                try store.postpone(id: id, until: now.addingTimeInterval(delay), reason: code, ifRunning: true, in: d)
            case .requeue:
                try store.postpone(id: id, until: job.nextRunAt, ifRunning: true, in: d)
            case .retry(let code):
                try store.retry(id: id, error: code, now: now, ifRunning: true, in: d)
            case .stale:
                break
            }
            // Any completed cloud call since the job began ends the backoff.
            if !disposition.isUsageLimit, next != UsageBackoff(),
               try BackgroundUsage.completedCloudCall(since: startedAt, in: d) {
                next.recordSuccess()
            }
            if next != backoff { try settings.setBackoff(next, in: d) }
            return next
        }
    }

    private func waitUntilIdle() async {
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func finishRun() {
        busy = false
        stopRequested = false
        let waiters = idleWaiters
        idleWaiters = []
        for w in waiters { w.resume() }
    }
}

private extension Duration {
    var milliseconds: Int64 { components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000 }
}
