import Foundation
import GRDB
import Storage

/// The read-only questions the planner asks about stored data.
public protocol PlannerData: Sendable {
    /// Per-hour focus seconds and snapshot counts for the hours in `[from, to)`; hours with
    /// neither may be omitted.
    func hourStats(from: Date, to: Date, calendar: Calendar) throws -> [HourStat]
    func newestSnapshotAt() throws -> Date?
    /// Wiki pages flagged dirty with at least `minMentions` mentions.
    func dirtyWikiPages(minMentions: Int) throws -> Int
    /// Chronicle, page or valid-fact rows with no embedding, or changed after it. Revision
    /// changes are caught by compaction step 6 (this ignores the revision).
    func pendingEmbeddings() throws -> Int
    func inlineOutputsSince(_ d: Date?) throws -> Int
    func dayChroniclesSince(_ d: Date?) throws -> Int
    func lastIdentityAt() throws -> Date?
    func dirtyChronicles() throws -> [(ChronicleLevel, String)]
}

public struct DatabasePlannerData: PlannerData {
    private let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    public func hourStats(from: Date, to: Date, calendar: Calendar) throws -> [HourStat] {
        let events = try ActivityStore(db).events(since: from)
        let captures: [Date] = try db.reader.read { d in
            try Date.fetchAll(d, sql: "SELECT captured_at FROM snapshots WHERE captured_at >= ? AND captured_at < ?",
                              arguments: [from, to])
        }
        var focus: [Date: (hour: DateInterval, seconds: TimeInterval, snapshots: Int)] = [:]
        func slot(for date: Date) -> DateInterval? { calendar.dateInterval(of: .hour, for: date) }
        for event in events where event.endedAt > event.startedAt {
            let start = max(event.startedAt, from), end = min(event.endedAt, to)
            var cursor = start
            while cursor < end, let hour = slot(for: cursor), hour.end > cursor {
                let overlap = min(hour.end, end).timeIntervalSince(cursor)
                var entry = focus[hour.start] ?? (hour, 0, 0)
                entry.seconds += overlap
                focus[hour.start] = entry
                cursor = hour.end
            }
        }
        for date in captures {
            guard let hour = slot(for: date) else { continue }
            var entry = focus[hour.start] ?? (hour, 0, 0)
            entry.snapshots += 1
            focus[hour.start] = entry
        }
        return focus.values.sorted { $0.hour.start < $1.hour.start }
            .map { HourStat(hour: $0.hour, focusSeconds: $0.seconds, snapshotCount: $0.snapshots) }
    }

    public func newestSnapshotAt() throws -> Date? {
        try db.reader.read { d in try Date.fetchOne(d, sql: "SELECT MAX(captured_at) FROM snapshots") }
    }

    public func dirtyWikiPages(minMentions: Int) throws -> Int {
        try db.reader.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM wiki_pages WHERE is_dirty = 1 AND mention_count >= ?",
                             arguments: [minMentions]) ?? 0
        }
    }

    public func pendingEmbeddings() throws -> Int {
        try EmbeddingStore(db).pendingSourceCount(identity: nil)
    }

    public func inlineOutputsSince(_ d: Date?) throws -> Int {
        try db.reader.read { db in
            if let d {
                return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM inline_outputs WHERE created_at > ?", arguments: [d]) ?? 0
            }
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM inline_outputs") ?? 0
        }
    }

    public func dayChroniclesSince(_ d: Date?) throws -> Int {
        try db.reader.read { db in
            if let d {
                return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chronicle WHERE level = 'day' AND generated_at > ?",
                                        arguments: [d]) ?? 0
            }
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chronicle WHERE level = 'day'") ?? 0
        }
    }

    public func lastIdentityAt() throws -> Date? {
        try db.reader.read { d in try Date.fetchOne(d, sql: "SELECT MAX(created_at) FROM identity") }
    }

    public func dirtyChronicles() throws -> [(ChronicleLevel, String)] {
        try db.reader.read { d in
            try Row.fetchAll(d, sql: "SELECT level, period_key FROM chronicle WHERE is_dirty = 1 ORDER BY period_start")
                .compactMap { row in
                    guard let level = ChronicleLevel(rawValue: row["level"]) else { return nil }
                    return (level, row["period_key"])
                }
        }
    }
}

/// Decides which jobs should exist (plan 4 Task 3).
///
/// - `hour` per `HourSpan` (see `HourBatcher` for the sparse-merge rule) and `time_ledger` per closed
///   hour with focus, from the planner watermark to the newest closed hour (an hour closes 5 minutes
///   after its end). The watermark starts at `now - 30 days` and advances to the newest closed hour's
///   end, or stays at the start of a held-back sparse span.
/// - `day_rollup` for a day 15 minutes after it ends, once every `hour` job overlapping it is
///   finished (`done`/`skipped`/`failed`) and at least one is `done`. `week_rollup` and `month_rollup`
///   follow once every day in them that has hour jobs is settled: no hour job unfinished and a
///   finished `day_rollup` (days whose hour jobs all skipped/failed, and days without hour jobs, never
///   block; F-10). `year_rollup` follows the same rule over its months.
/// - Dirty chronicles whose job is `done` are returned for requeue (see `dirtyRequeues`).
/// - The planner performs no writes: it returns a `JobPlan` (specs, new watermark, requeues).
/// - `working_memory` for the current 10-minute slot when there is a snapshot newer than
///   `memory.wm.lastSnapshotAt` and the user touched the Mac within 10 minutes; `wiki_rewrite` per
///   3-hour slot when pages with >= 2 mentions are dirty; `embeddings` per hour when rows are pending;
///   `style_notes` per day (04:00) with >= 3 new inline outputs; `identity` per ISO week with >= 3 new
///   day chronicles; `compaction` per day (03:00).
public struct JobPlanner: JobPlanning {
    public static let watermarkKey = "memory.plannerWatermark"
    public static let workingMemorySnapshotKey = "memory.wm.lastSnapshotAt"
    public static let lastStyleRunKey = "memory.lastStyleRunAt"

    public static let horizon: TimeInterval = 30 * 86_400
    public static let hourGrace: TimeInterval = 300
    public static let rollupGrace: TimeInterval = 15 * 60
    static let activeIdleLimit: TimeInterval = 600
    /// Rollup candidates come from hour jobs this far back (the horizon plus a week of retries).
    static let rollupLookback: TimeInterval = horizon + 7 * 86_400

    private let db: AppDatabase
    private let data: any PlannerData
    private let calendar: Calendar
    private let jobs: JobStore
    private let settings: SettingsStore

    public init(db: AppDatabase, data: any PlannerData, calendar: Calendar) {
        self.db = db; self.data = data; self.calendar = calendar
        jobs = JobStore(db); settings = SettingsStore(db)
    }

    /// Reads only; the scheduler commits the result atomically.
    public func plan(_ s: SchedulerSignals) throws -> JobPlan {
        let hours = try planHours(s)
        var specs = hours.specs
        specs += try planRollups(s)
        specs += try planPeriodic(s)
        return JobPlan(specs: specs, watermark: hours.watermark, requeues: try dirtyRequeues())
    }

    // MARK: Hours and time ledger

    private func planHours(_ s: SchedulerSignals) throws -> (specs: [JobSpec], watermark: Date?) {
        let now = s.now
        let horizonStart = now.addingTimeInterval(-Self.horizon)
        let watermark = max(try settings.value(Date.self, forKey: Self.watermarkKey) ?? horizonStart, horizonStart)
        // Hours that start before the horizon are out: the earliest span never begins before now - 30 d.
        let closed = PeriodKey.closedHours(from: watermark, to: now.addingTimeInterval(-Self.hourGrace), calendar: calendar)
            .filter { $0.start >= horizonStart }
        guard let newest = closed.last, let first = closed.first else { return ([], nil) }
        let stats = try data.hourStats(from: first.start, to: newest.end, calendar: calendar)
        let batch = HourBatcher.batch(stats, newestClosedHourEnd: newest.end, now: now, calendar: calendar)

        var specs = batch.spans.map {
            JobSpec(kind: .hour, periodKey: $0.key, periodStart: $0.start, periodEnd: $0.end,
                    notBefore: $0.end.addingTimeInterval(Self.hourGrace))
        }
        specs += stats.filter { $0.focusSeconds > 0 && $0.hour.end <= newest.end }.map {
            JobSpec(kind: .timeLedger, periodKey: PeriodKey.key(.hour, for: $0.hour.start, calendar: calendar),
                    periodStart: $0.hour.start, periodEnd: $0.hour.end,
                    notBefore: $0.hour.end.addingTimeInterval(Self.hourGrace))
        }
        let advanced = batch.waitingFrom ?? newest.end
        return (specs, advanced > watermark ? advanced : nil)
    }

    // MARK: Rollups

    private enum State: Equatable {
        /// Nothing to roll up (no hour jobs, or none finished successfully).
        case empty
        /// Not ended yet, or something below it is unfinished.
        case pending
        /// Everything below is settled and this period has no rollup job yet.
        case needsRollup
        /// Its rollup job is finished (`done`, `skipped` or `failed`).
        case settled
    }

    private static let finished: Set<JobStatus> = [.done, .skipped, .failed]

    private func planRollups(_ s: SchedulerSignals) throws -> [JobSpec] {
        let now = s.now
        let recent = try jobs.jobs(kind: .hour,
                                   overlapping: DateInterval(start: now.addingTimeInterval(-Self.rollupLookback), end: now))
        var specs: [JobSpec] = []
        var visited = Set<String>()
        for level in [ChronicleLevel.day, .week, .month, .year] {
            for job in recent {
                guard let start = job.periodStart else { continue }
                let period = PeriodKey.interval(level, containing: start, calendar: calendar)
                let key = PeriodKey.key(level, for: period.start, calendar: calendar)
                guard visited.insert(level.rawValue + key).inserted,
                      try state(level, period, now: now) == .needsRollup else { continue }
                specs.append(JobSpec(kind: level.jobKind, periodKey: key, periodStart: period.start, periodEnd: period.end,
                                     notBefore: period.end.addingTimeInterval(Self.rollupGrace)))
            }
        }
        return specs
    }

    private func state(_ level: ChronicleLevel, _ period: DateInterval, now: Date) throws -> State {
        guard period.end.addingTimeInterval(Self.rollupGrace) <= now else { return .pending }
        let key = PeriodKey.key(level, for: period.start, calendar: calendar)
        if let job = try jobs.job(kind: level.jobKind, periodKey: key) {
            return Self.finished.contains(job.status) ? .settled : .pending
        }
        if level == .day {
            let hourJobs = try jobs.jobs(kind: .hour, overlapping: period)
            if hourJobs.isEmpty { return .empty }
            if hourJobs.contains(where: { !Self.finished.contains($0.status) }) { return .pending }
            return hourJobs.contains(where: { $0.status == .done }) ? .needsRollup : .empty
        }
        let childLevel: ChronicleLevel = level == .year ? .month : .day
        var anySettled = false
        for child in children(of: period, level: childLevel) {
            switch try state(childLevel, child, now: now) {
            case .pending, .needsRollup: return .pending
            case .settled: anySettled = true
            case .empty: break
            }
        }
        return anySettled ? .needsRollup : .empty
    }

    private func children(of period: DateInterval, level: ChronicleLevel) -> [DateInterval] {
        var result: [DateInterval] = []
        var cursor = period.start
        while cursor < period.end {
            let child = PeriodKey.interval(level, containing: cursor, calendar: calendar)
            guard child.end > cursor else { break }
            result.append(child)
            cursor = child.end
        }
        return result
    }

    // MARK: Dirty chronicles

    /// A dirty chronicle whose job is `done` goes back to `pending`: a runner clears `is_dirty` when
    /// it writes, so a chronicle still dirty after a done job was marked dirty after it. A job that
    /// was `skipped` or `failed` is terminal (it would loop otherwise), and a pending or running job
    /// keeps its retry backoff. (`chronicle` has no dirty-since column to compare with `updated_at`.)
    private func dirtyRequeues() throws -> [JobRef] {
        try data.dirtyChronicles().compactMap { level, key in
            guard let job = try jobs.job(kind: level.jobKind, periodKey: key), job.status == .done else { return nil }
            return JobRef(kind: level.jobKind, periodKey: key)
        }
    }

    // MARK: Periodic jobs

    private func planPeriodic(_ s: SchedulerSignals) throws -> [JobSpec] {
        let now = s.now
        var specs: [JobSpec] = []
        let day = PeriodKey.interval(.day, containing: now, calendar: calendar)
        let dayKey = PeriodKey.key(.day, for: now, calendar: calendar)

        if let newest = try data.newestSnapshotAt(), s.idleSeconds < Self.activeIdleLimit {
            let last = try settings.value(Date.self, forKey: Self.workingMemorySnapshotKey)
            if last.map({ newest > $0 }) ?? true {
                let slot = PeriodKey.workingMemoryInterval(now, calendar: calendar)
                specs.append(JobSpec(kind: .workingMemory, periodKey: PeriodKey.workingMemorySlot(now, calendar: calendar),
                                     periodStart: slot.start, periodEnd: slot.end, notBefore: now))
            }
        }
        if try data.dirtyWikiPages(minMentions: WikiRewritePipeline.minMentions) > 0 {
            let slot = PeriodKey.wikiSlotInterval(now, calendar: calendar)
            specs.append(JobSpec(kind: .wikiRewrite, periodKey: PeriodKey.wikiSlot(now, calendar: calendar),
                                 periodStart: slot.start, periodEnd: slot.end, notBefore: now))
        }
        if try data.pendingEmbeddings() > 0 {
            let hour = PeriodKey.interval(.hour, containing: now, calendar: calendar)
            specs.append(JobSpec(kind: .embeddings, periodKey: PeriodKey.key(.hour, for: now, calendar: calendar),
                                 periodStart: hour.start, periodEnd: hour.end, notBefore: now))
        }
        let lastStyle = try settings.value(Date.self, forKey: Self.lastStyleRunKey)
        if try data.inlineOutputsSince(lastStyle) >= 3 {
            specs.append(JobSpec(kind: .styleNotes, periodKey: dayKey, periodStart: day.start, periodEnd: day.end,
                                 notBefore: at(hour: 4, in: day)))
        }
        if try data.dayChroniclesSince(try data.lastIdentityAt()) >= 3 {
            let week = PeriodKey.interval(.week, containing: now, calendar: calendar)
            specs.append(JobSpec(kind: .identity, periodKey: PeriodKey.key(.week, for: now, calendar: calendar),
                                 periodStart: week.start, periodEnd: week.end, notBefore: now))
        }
        specs.append(JobSpec(kind: .compaction, periodKey: dayKey, periodStart: day.start, periodEnd: day.end,
                             notBefore: at(hour: 3, in: day)))
        return specs
    }

    private func at(hour: Int, in day: DateInterval) -> Date {
        calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day.start) ?? day.start.addingTimeInterval(Double(hour) * 3_600)
    }
}
