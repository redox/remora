import Foundation
import GRDB
import Memory
import Storage

/// Plans the proactive jobs (passed to `MemoryScheduler` inside `CompositePlanner` after
/// `JobPlanner`). Like every planner it only reads and never sets the watermark. A window is
/// planned only while it is open, so catch-up after sleep means "planned on wake while the window
/// still runs" and a passed window is never planned:
/// - `morning_brief` for today while 08:00–12:00, `evening_wrap` while 16:00–24:00 (key = day key,
///   `notBefore` = the window start);
/// - `nudge_scan` for the current 30-minute slot (key = day key + `T` + `HH:mm`) while 09:00–19:00,
///   when fewer than 3 nudges came today and the last one is at least 90 minutes old.
/// - a brief skipped for a reason that may clear up (`retryable`) is requeued, guarded on its
///   status still being `skipped`, so a Mac woken before any capture still gets that day's brief.
/// - `routine_scan` for the local week, once at least seven days of history are available.
/// Nothing is planned when proactive messages are off or background memory is off (no evidence;
/// the scheduler gate denies these kinds then too).
public struct ProactivePlanner: JobPlanning {
    public static let nudgeHours = 9..<19
    public static let slotMinutes = 30
    public static let dailyNudgeCap = 3
    public static let nudgeGap: TimeInterval = 90 * 60

    private let db: AppDatabase
    private let calendar: Calendar
    private let enabled: @Sendable () -> Bool

    public init(db: AppDatabase, calendar: Calendar, enabled: @escaping @Sendable () -> Bool) {
        self.db = db; self.calendar = calendar; self.enabled = enabled
    }

    public func plan(_ s: SchedulerSignals) throws -> JobPlan {
        guard enabled(), s.memoryEnabled else { return JobPlan() }
        let now = s.now
        let dayKey = PeriodKey.key(.day, for: now, calendar: calendar)
        var specs: [JobSpec] = []
        var requeues: [JobRef] = []
        for (kind, job) in [(BriefKind.morning, JobKind.morningBrief), (.evening, .eveningWrap)] {
            let w = kind.window(day: now, calendar: calendar)
            if now >= w.start, now < w.end {
                specs.append(JobSpec(kind: job, periodKey: dayKey, periodStart: w.start, periodEnd: w.end, notBefore: w.start))
                if try retryable(kind, job: job, dayKey: dayKey, window: w, now: now) {
                    requeues.append(JobRef(kind: job, periodKey: dayKey, ifStatusIn: [.skipped]))
                }
            }
        }
        let slot = nudgeSlot(now)
        let routine = (try? routinePlan(now: now)) ?? JobPlan()
        let hasRoutineWork = !routine.specs.isEmpty || !routine.requeues.isEmpty
        let canNudge = try (slot != nil || hasRoutineWork) && nudgeAllowed(now)
        if let slot, canNudge {
            let key = dayKey + "T" + ProactivePrompt.stamp(slot.start, calendar: calendar, format: "HH:mm")
            specs.append(JobSpec(kind: .nudgeScan, periodKey: key, periodStart: slot.start, periodEnd: slot.end,
                                 notBefore: slot.start))
        }
        if canNudge {
            specs += routine.specs
            requeues += routine.requeues
        }
        return JobPlan(specs: specs, requeues: requeues)
    }

    /// A skipped scan can retry while its week is still open if control settings, evidence, or
    /// the inbox gate changed. A completed scan with nothing new waits until the next week.
    private func routinePlan(now: Date) throws -> JobPlan {
        guard try !SettingsStore(db).isPaused(now: now),
              try RoutineScanRunner.hasHistory(db, at: now, calendar: calendar) else { return JobPlan() }
        let key = PeriodKey.key(.week, for: now, calendar: calendar)
        if let job = try JobStore(db).job(kind: .routineScan, periodKey: key) {
            guard job.status == .skipped, let reason = job.lastError,
                  RoutineScanRunner.retryableSkips.contains(reason),
                  job.updatedAt <= now.addingTimeInterval(-Self.retryAfter) else { return JobPlan() }
            return JobPlan(requeues: [JobRef(kind: .routineScan, periodKey: key, ifStatusIn: [.skipped])])
        }
        let week = PeriodKey.interval(.week, containing: now, calendar: calendar)
        return JobPlan(specs: [JobSpec(kind: .routineScan, periodKey: key, periodStart: week.start,
                                      periodEnd: week.end, notBefore: now)])
    }

    /// Skip codes that may clear up later in the window (activity arrives, the cloud comes back,
    /// the forgotten evidence is rebuilt). Never `unverified` (the model's draft failed twice),
    /// `duplicate` or `disabled`.
    public static let retryableSkips: Set<String> = ["no activity", "cloud_denied", "evidence changed"]
    /// A skipped brief is retried at most this often…
    public static let retryAfter: TimeInterval = 30 * 60
    /// …and only while this much of its window is left.
    public static let retryMargin: TimeInterval = 15 * 60

    /// Whether today's skipped brief should run again: skipped for a retryable reason at least
    /// 30 min ago, at least 15 min of the window left, and nothing delivered for the day. The
    /// scheduler requeues it only if it is still `skipped` when it commits the plan.
    func retryable(_ kind: BriefKind, job: JobKind, dayKey: String, window: DateInterval, now: Date) throws -> Bool {
        guard now < window.end.addingTimeInterval(-Self.retryMargin),
              let row = try JobStore(db).job(kind: job, periodKey: dayKey),
              row.status == .skipped, let reason = row.lastError, Self.retryableSkips.contains(reason),
              row.updatedAt <= now.addingTimeInterval(-Self.retryAfter) else { return false }
        let key = BriefRunner.dedupeKey(kind, dayKey: dayKey)
        return try !db.reader.read { d in
            try Bool.fetchOne(d, sql: "SELECT 1 FROM inbox_messages WHERE dedupe_key = ?", arguments: [key]) ?? false
        }
    }

    /// The 30-minute slot containing `now`, when inside 09:00–19:00.
    func nudgeSlot(_ now: Date) -> DateInterval? {
        let c = calendar.dateComponents([.hour, .minute], from: now)
        guard let hour = c.hour, let minute = c.minute, Self.nudgeHours.contains(hour) else { return nil }
        let slotMinute = minute / Self.slotMinutes * Self.slotMinutes
        guard let start = calendar.date(bySettingHour: hour, minute: slotMinute, second: 0, of: now,
                                        matchingPolicy: .nextTime) else { return nil }
        return DateInterval(start: start, duration: Double(Self.slotMinutes) * 60)
    }

    func nudgeAllowed(_ now: Date) throws -> Bool {
        let inbox = InboxStore(db)
        guard try inbox.nudgeCount(since: calendar.startOfDay(for: now)) < Self.dailyNudgeCap else { return false }
        if let last = try inbox.lastNudgeAt(), now.timeIntervalSince(last) < Self.nudgeGap { return false }
        return true
    }
}
