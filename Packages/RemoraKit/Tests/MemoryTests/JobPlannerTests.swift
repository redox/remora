import Foundation
import GRDB
import Testing
import Storage
@testable import Memory

private struct FakeData: PlannerData {
    var stats: [HourStat] = []
    var newestSnapshot: Date?
    var dirtyPages = 0
    var pending = 0
    var inlineOutputs = 0
    var dayChronicles = 0
    var identityAt: Date?
    var dirty: [(ChronicleLevel, String)] = []

    func hourStats(from: Date, to: Date, calendar: Calendar) throws -> [HourStat] {
        stats.filter { $0.hour.start >= from && $0.hour.end <= to }
    }
    func newestSnapshotAt() throws -> Date? { newestSnapshot }
    func dirtyWikiPages(minMentions: Int) throws -> Int { dirtyPages }
    func pendingEmbeddings() throws -> Int { pending }
    func inlineOutputsSince(_ d: Date?) throws -> Int { inlineOutputs }
    func dayChroniclesSince(_ d: Date?) throws -> Int { dayChronicles }
    func lastIdentityAt() throws -> Date? { identityAt }
    func dirtyChronicles() throws -> [(ChronicleLevel, String)] { dirty }
}

private func busy(_ day: Date, hour: Int, focus: TimeInterval = 3_000) -> HourStat {
    let start = paris.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
    return HourStat(hour: DateInterval(start: start, end: start.addingTimeInterval(3_600)), focusSeconds: focus, snapshotCount: 3)
}

private func planner(_ db: AppDatabase, _ data: FakeData) -> JobPlanner {
    JobPlanner(db: db, data: data, calendar: paris)
}

private func kinds(_ plan: JobPlan, _ kind: JobKind) -> [JobSpec] { plan.specs.filter { $0.kind == kind } }
private func kinds(_ specs: [JobSpec], _ kind: JobKind) -> [JobSpec] { specs.filter { $0.kind == kind } }

/// Enqueues a job with a period and sets its status.
private func seedJob(_ db: AppDatabase, _ kind: JobKind, _ key: String, _ start: Date, _ end: Date, _ status: JobStatus) throws {
    let store = JobStore(db)
    try store.enqueue([JobSpec(kind: kind, periodKey: key, periodStart: start, periodEnd: end, notBefore: start)], now: start)
    let id = try #require(try store.job(kind: kind, periodKey: key)?.id)
    if status != .pending { try store.complete(id: id, status: status, now: end) }
}

private func seedHour(_ db: AppDatabase, _ day: Date, _ hour: Int, _ status: JobStatus) throws {
    let start = paris.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
    try seedJob(db, .hour, PeriodKey.key(.hour, for: start, calendar: paris), start, start.addingTimeInterval(3_600), status)
}

private func seedDayRollup(_ db: AppDatabase, _ day: Date, _ status: JobStatus) throws {
    let i = PeriodKey.interval(.day, containing: day, calendar: paris)
    try seedJob(db, .dayRollup, PeriodKey.key(.day, for: day, calendar: paris), i.start, i.end, status)
}

/// Review Focus 2: the Mac was offline for a week. Sparse hours merge, the oldest span runs first,
/// and no rollup exists before its hours are done.
@Test func weekOfflineCatchUpOldestFirstWithSparseMerge() async throws {
    let db = try AppDatabase.inMemory()
    var data = FakeData()
    for back in 1...7 {
        let day = paris.date(byAdding: .day, value: -back, to: t0)!
        // 09–11 sparse (200 + 200 + 300 s = 700 s ≥ 600 → one span of 3 hours), 14h busy.
        data.stats += [busy(day, hour: 9, focus: 200), busy(day, hour: 10, focus: 200), busy(day, hour: 11, focus: 300),
                       busy(day, hour: 14)]
    }
    let sched = planner(db, data)
    let specs = try sched.plan(signals()).specs
    let hourSpecs = kinds(specs, .hour)
    #expect(hourSpecs.count == 14)
    #expect(kinds(specs, .dayRollup).isEmpty && kinds(specs, .weekRollup).isEmpty)
    #expect(kinds(specs, .timeLedger).count == 28)
    let lengths = Set(hourSpecs.map { $0.periodEnd!.timeIntervalSince($0.periodStart!) })
    #expect(lengths == [10_800, 3_600], "\(lengths)")

    try JobStore(db).enqueue(specs, now: t0)
    // Oldest first among hour jobs, whatever the insertion order.
    let first = try #require(try JobStore(db).nextDue(now: t0, kinds: [.hour]))
    #expect(first.periodKey == "2026-11-13T09+0100")
    #expect(first.periodEnd == date(2026, 11, 13, 12))

    // Through the scheduler: hour jobs run oldest first; the day rollups appear only afterwards.
    let ran = FakeRunner()
    let scheduler = MemoryScheduler(db: db, runners: runners(ran, for: [.hour]), planner: sched, calendar: paris,
                                    now: { t0 })
    _ = await scheduler.tick(signals(idle: 300))
    let starts = ran.calls.map { $0.job.periodStart! }
    #expect(starts.count == 14 && starts == starts.sorted())
    let beforeSecondTick = try JobStore(db).counts()
    let rollups = try JobStore(db).jobs(kind: .dayRollup, overlapping: DateInterval(start: date(2026, 1, 1), end: date(2027, 1, 1)))
    #expect(rollups.isEmpty)
    #expect(beforeSecondTick[.done] == 14)
    // Every hour job is done: the next plan enqueues one day rollup per past day.
    let later = try sched.plan(signals()).specs
    #expect(kinds(later, .dayRollup).map(\.periodKey).sorted() ==
            (1...7).map { PeriodKey.key(.day, for: paris.date(byAdding: .day, value: -$0, to: t0)!, calendar: paris) }.sorted())
    #expect(kinds(later, .hour).isEmpty)
}

@Test func planningTwiceDoesNotReplanHours() async throws {
    let db = try AppDatabase.inMemory()
    var data = FakeData()
    data.stats = [busy(date(2026, 11, 19), hour: 10)]
    let p = planner(db, data)
    let first = try p.plan(signals())
    #expect(kinds(first, .hour).count == 1)
    #expect(first.watermark == date(2026, 11, 20, 13))  // the 13 hour closed 5 minutes ago
    // The planner writes nothing; the scheduler commits the plan.
    #expect(try SettingsStore(db).value(Date.self, forKey: JobPlanner.watermarkKey) == nil)
    let scheduler = MemoryScheduler(db: db, runners: runners(FakeRunner(), for: []), planner: p, calendar: paris, now: { t0 })
    _ = await scheduler.tick(signals())
    #expect(try SettingsStore(db).value(Date.self, forKey: JobPlanner.watermarkKey) == date(2026, 11, 20, 13))
    let second = try p.plan(signals())
    #expect(kinds(second, .hour).isEmpty && second.watermark == nil)
}

@Test func hourGraceDelaysTheNewestHour() throws {
    let db = try AppDatabase.inMemory()
    var data = FakeData()
    data.stats = [busy(date(2026, 11, 20), hour: 13)]
    let early = try planner(db, data).plan(signals(now: date(2026, 11, 20, 14, 4)))
    #expect(kinds(early, .hour).isEmpty)
    let after = try planner(db, data).plan(signals(now: date(2026, 11, 20, 14, 5)))
    #expect(kinds(after, .hour).map(\.periodKey) == ["2026-11-20T13+0100"])
}

@Test func trailingSparseHourWaitsAndHoldsTheWatermarkAtItsStart() throws {
    let db = try AppDatabase.inMemory()
    var data = FakeData()
    data.stats = [busy(date(2026, 11, 20), hour: 13, focus: 100)]
    let now = date(2026, 11, 20, 14, 20)
    #expect(kinds(try planner(db, data).plan(signals(now: now)), .hour).isEmpty)
    #expect(try planner(db, data).plan(signals(now: now)).watermark == date(2026, 11, 20, 13))
    // The next hour has closed without activity: the span is final.
    let later = try planner(db, data).plan(signals(now: date(2026, 11, 20, 15, 10)))
    #expect(kinds(later, .hour).map(\.periodKey) == ["2026-11-20T13+0100"])
}

@Test func dayRollupWaitsForAllHours() throws {
    let db = try AppDatabase.inMemory()
    let day = date(2026, 11, 19)
    try seedHour(db, day, 9, .done)
    try seedHour(db, day, 10, .done)
    try seedHour(db, day, 11, .pending)
    let now = date(2026, 11, 20, 10)
    #expect(kinds(try planner(db, FakeData()).plan(signals(now: now)), .dayRollup).isEmpty)
    let id = try #require(try JobStore(db).job(kind: .hour, periodKey: "2026-11-19T11+0100")?.id)
    try JobStore(db).complete(id: id, status: .done, now: now)
    let specs = kinds(try planner(db, FakeData()).plan(signals(now: now)), .dayRollup)
    #expect(specs.map(\.periodKey) == ["2026-11-19"])
    #expect(specs.first?.periodStart == date(2026, 11, 19) && specs.first?.periodEnd == date(2026, 11, 20))
    #expect(specs.first?.notBefore == date(2026, 11, 20, 0, 15))
}

@Test func dayRollupNeedsADoneHourAndTheGracePeriod() throws {
    let db = try AppDatabase.inMemory()
    // 2026-11-17 has only skipped/failed hours; 2026-11-18 has a done one.
    try seedHour(db, date(2026, 11, 17), 9, .skipped)
    try seedHour(db, date(2026, 11, 17), 10, .failed)
    try seedHour(db, date(2026, 11, 18), 9, .done)
    // The day ended at 2026-11-19 00:00; the rollup waits 15 minutes more.
    #expect(kinds(try planner(db, FakeData()).plan(signals(now: date(2026, 11, 19, 0, 14))), .dayRollup).isEmpty)
    #expect(kinds(try planner(db, FakeData()).plan(signals(now: date(2026, 11, 19, 0, 15))), .dayRollup).map(\.periodKey) == ["2026-11-18"])
    // Later, 2026-11-17 (no done hour) still gets none.
    #expect(kinds(try planner(db, FakeData()).plan(signals(now: date(2026, 11, 20, 10))), .dayRollup).map(\.periodKey) == ["2026-11-18"])
}

@Test func weekRollupWaitsForSettledDaysButIgnoresEmptyOnes() throws {
    let db = try AppDatabase.inMemory()
    // ISO week 2026-W46: Mon 2026-11-09 … Sun 2026-11-15. Hour jobs on Mon and Wed only.
    try seedHour(db, date(2026, 11, 9), 10, .done)
    try seedHour(db, date(2026, 11, 11), 10, .done)
    try seedDayRollup(db, date(2026, 11, 9), .done)
    let now = date(2026, 11, 20, 10)
    #expect(kinds(try planner(db, FakeData()).plan(signals(now: now)), .weekRollup).isEmpty)  // Wednesday not rolled
    try seedDayRollup(db, date(2026, 11, 11), .done)
    let specs = kinds(try planner(db, FakeData()).plan(signals(now: now)), .weekRollup)
    #expect(specs.map(\.periodKey) == ["2026-W46"])
    #expect(specs.first?.notBefore == date(2026, 11, 16, 0, 15))
    // The current week (W47) never rolls early.
    try seedHour(db, date(2026, 11, 17), 10, .done)
    try seedDayRollup(db, date(2026, 11, 17), .done)
    #expect(kinds(try planner(db, FakeData()).plan(signals(now: now)), .weekRollup).map(\.periodKey) == ["2026-W46"])
}

@Test func monthRollupFromDaysAndYearFromMonths() throws {
    let db = try AppDatabase.inMemory()
    let now = date(2027, 1, 3, 10)
    // December 2026 has two active days, November one.
    for day in [date(2026, 11, 30), date(2026, 12, 14), date(2026, 12, 30)] {
        try seedHour(db, day, 10, .done)
    }
    try seedDayRollup(db, date(2026, 11, 30), .done)
    try seedDayRollup(db, date(2026, 12, 14), .done)
    // December waits for 12-30; November (one rolled day) is ready.
    #expect(kinds(try planner(db, FakeData()).plan(signals(now: now)), .monthRollup).map(\.periodKey) == ["2026-11"])
    try seedDayRollup(db, date(2026, 12, 30), .done)
    let months = kinds(try planner(db, FakeData()).plan(signals(now: now)), .monthRollup)
    #expect(months.map(\.periodKey).sorted() == ["2026-11", "2026-12"])
    #expect(kinds(try planner(db, FakeData()).plan(signals(now: now)), .yearRollup).isEmpty)  // months not rolled
    try seedJob(db, .monthRollup, "2026-11", date(2026, 11, 1), date(2026, 12, 1), .done)
    #expect(kinds(try planner(db, FakeData()).plan(signals(now: now)), .yearRollup).isEmpty)
    try seedJob(db, .monthRollup, "2026-12", date(2026, 12, 1), date(2027, 1, 1), .done)
    let years = kinds(try planner(db, FakeData()).plan(signals(now: now)), .yearRollup)
    #expect(years.map(\.periodKey) == ["2026"])
    #expect(years.first?.periodStart == date(2026, 1, 1) && years.first?.periodEnd == date(2027, 1, 1))
}

@Test func horizonCapsBacklogAt30Days() throws {
    let db = try AppDatabase.inMemory()
    var data = FakeData()
    // 30 x 86,400 s back from 14:20 +0100 is 2026-10-21 15:20 +0200 (the clocks changed in between): the 15:00 hour straddles it.
    let now = date(2026, 11, 20, 14, 20)
    for back in 1...90 { data.stats.append(busy(paris.date(byAdding: .day, value: -back, to: now)!, hour: 14)) }
    let edge = paris.date(byAdding: .day, value: -30, to: now)!
    data.stats += [busy(edge, hour: 15), busy(edge, hour: 16)]
    let specs = kinds(try planner(db, data).plan(signals(now: now)), .hour)
    let earliest = try #require(specs.map { $0.periodStart! }.min())
    // The 14:00 and 15:00 hours on 10-21 start before the horizon and are excluded; 16:00 is the earliest.
    #expect(earliest == date(2026, 10, 21, 16))
    #expect(earliest >= now.addingTimeInterval(-30 * 86_400))
    #expect(specs.count == 30)  // 29 days of 14:00 hours (back = 1…29) plus the 10-21 16:00 hour
}

@Test func workingMemoryOnlyWhenNewSnapshotsAndActive() throws {
    let db = try AppDatabase.inMemory()
    var data = FakeData()
    data.newestSnapshot = date(2026, 11, 20, 13, 58)
    let now = date(2026, 11, 20, 14, 7)
    // New snapshots, user active: planned for the 10-minute slot.
    let active = kinds(try planner(db, data).plan(signals(now: now, idle: 30)), .workingMemory)
    #expect(active.map(\.periodKey) == ["2026-11-20T14+0100:00"])
    #expect(active.first?.periodStart == date(2026, 11, 20, 14) && active.first?.periodEnd == date(2026, 11, 20, 14, 10))
    // User idle for 10 minutes or more: nothing.
    #expect(kinds(try planner(db, data).plan(signals(now: now, idle: 600)), .workingMemory).isEmpty)
    // No snapshot newer than the last working-memory run: nothing.
    try SettingsStore(db).setValue(date(2026, 11, 20, 13, 58), forKey: JobPlanner.workingMemorySnapshotKey)
    #expect(kinds(try planner(db, data).plan(signals(now: now, idle: 30)), .workingMemory).isEmpty)
    try SettingsStore(db).setValue(date(2026, 11, 20, 13, 0), forKey: JobPlanner.workingMemorySnapshotKey)
    #expect(kinds(try planner(db, data).plan(signals(now: now, idle: 30)), .workingMemory).count == 1)
    // No snapshots at all: nothing.
    data.newestSnapshot = nil
    #expect(kinds(try planner(db, data).plan(signals(now: now, idle: 30)), .workingMemory).isEmpty)
}

@Test func dirtyChronicleIsRequeued() throws {
    let db = try AppDatabase.inMemory()
    let day = date(2026, 11, 19)
    try seedHour(db, day, 9, .done)
    try seedDayRollup(db, day, .done)
    try seedHour(db, day, 10, .pending)
    try seedHour(db, day, 11, .skipped)
    try seedHour(db, day, 12, .failed)
    var data = FakeData()
    data.dirty = [(.day, "2026-11-19"), (.hour, "2026-11-19T10+0100"), (.hour, "2026-11-19T11+0100"),
                  (.hour, "2026-11-19T12+0100"), (.week, "2026-W99")]
    let plan = try planner(db, data).plan(signals())
    // Only the done job returns. A pending job keeps its backoff, skipped/failed jobs are terminal
    // (they would loop), and a chronicle without a job is ignored.
    #expect(plan.requeues == [JobRef(kind: .dayRollup, periodKey: "2026-11-19")])
}

@Test func periodicJobsFollowTheirConditions() throws {
    let db = try AppDatabase.inMemory()
    let quiet = try planner(db, FakeData()).plan(signals()).specs
    #expect(quiet.map(\.kind) == [.compaction])
    #expect(quiet.first?.periodKey == "2026-11-20" && quiet.first?.notBefore == date(2026, 11, 20, 3))

    var data = FakeData()
    data.dirtyPages = 1; data.pending = 4; data.inlineOutputs = 3; data.dayChronicles = 3
    let specs = try planner(db, data).plan(signals()).specs
    #expect(kinds(specs, .wikiRewrite).map(\.periodKey) == ["2026-11-20T12+0100"])
    #expect(kinds(specs, .embeddings).map(\.periodKey) == ["2026-11-20T14+0100"])
    #expect(kinds(specs, .styleNotes).map(\.periodKey) == ["2026-11-20"])
    #expect(kinds(specs, .styleNotes).first?.notBefore == date(2026, 11, 20, 4))
    #expect(kinds(specs, .identity).map(\.periodKey) == ["2026-W47"])

    data.inlineOutputs = 2; data.dayChronicles = 2
    let fewer = try planner(db, data).plan(signals()).specs
    #expect(kinds(fewer, .styleNotes).isEmpty && kinds(fewer, .identity).isEmpty)
}

@Test func dstFallBackDayPlansDistinctHourKeys() throws {
    let db = try AppDatabase.inMemory()
    var data = FakeData()
    let day = date(2026, 10, 25)
    let night = PeriodKey.closedHours(from: day, to: day.addingTimeInterval(5 * 3_600), calendar: paris)  // 00:00 +0200 … 03:00 +0100, 5 hours
    #expect(night.count == 5)
    data.stats = night.map { HourStat(hour: $0, focusSeconds: 3_000, snapshotCount: 2) }
    let specs = kinds(try planner(db, data).plan(signals(now: date(2026, 10, 26, 12))), .hour)
    // t0 horizon: 2026-10-26 12:00 - 30 d reaches back to 2026-09-26, so all five hours are in.
    #expect(specs.count == 5)
    #expect(Set(specs.map(\.periodKey)).count == 5)
    #expect(specs.map(\.periodKey).contains("2026-10-25T02+0200") && specs.map(\.periodKey).contains("2026-10-25T02+0100"))
}

// MARK: - DatabasePlannerData and the shared pending-embedding query

@Test func databasePlannerDataCountsFocusAndSnapshotsPerHour() throws {
    let db = try AppDatabase.inMemory()
    // Focus 09:50–10:20 splits 600 s / 1,200 s over two hours.
    try db.writer.write { d in
        var event = ActivityEvent(app: "Xcode", startedAt: date(2026, 11, 20, 9, 50), endedAt: date(2026, 11, 20, 10, 20))
        try event.insert(d)
    }
    _ = try SnapshotStore(db).insert(Snapshot(capturedAt: date(2026, 11, 20, 10, 5), app: "Xcode", text: "a", contentHash: "h1", source: .ax))
    _ = try SnapshotStore(db).insert(Snapshot(capturedAt: date(2026, 11, 20, 11, 5), app: "Xcode", text: "b", contentHash: "h2", source: .ax))
    let data = DatabasePlannerData(db: db)
    let stats = try data.hourStats(from: date(2026, 11, 20, 9), to: date(2026, 11, 20, 12), calendar: paris)
    #expect(stats.map(\.hour.start) == [date(2026, 11, 20, 9), date(2026, 11, 20, 10), date(2026, 11, 20, 11)])
    #expect(stats.map(\.snapshotCount) == [0, 1, 1])
    #expect(stats.map(\.focusSeconds) == [600, 1_200, 0])
    #expect(try data.newestSnapshotAt() == date(2026, 11, 20, 11, 5))
}

@Test func pendingSourceCountIsSharedAndIdentityAware() throws {
    let db = try AppDatabase.inMemory()
    let created = date(2026, 11, 20, 12)
    try db.writer.write { d in
        try d.execute(sql: """
            INSERT INTO chronicle (level, period_key, period_start, period_end, summary, generated_at)
            VALUES ('day', '2026-11-19', ?, ?, 's', ?)
            """, arguments: [date(2026, 11, 19), date(2026, 11, 20), created])
        try d.execute(sql: """
            INSERT INTO wiki_pages (slug, type, title, first_seen, last_seen, updated_at)
            VALUES ('p', 'topic', 'P', ?, ?, ?)
            """, arguments: [created, created, created])
        try d.execute(sql: """
            INSERT INTO wiki_facts (slug, fact, norm_key, subject, basis, worth, valid_at, recorded_at, last_confirmed_at)
            VALUES ('p', 'f', 'f', 'user', 'inferred', 'core', ?, ?, ?)
            """, arguments: [created, created, created])
    }
    let store = EmbeddingStore(db)
    #expect(try store.pendingSourceCount(identity: nil) == 3)
    #expect(try DatabasePlannerData(db: db).pendingEmbeddings() == 3)
    try db.writer.write { d in
        for (table, id) in [("chronicle", 1), ("wiki_pages", 1), ("wiki_facts", 1)] {
            try d.execute(sql: """
                INSERT INTO embeddings (owner_table, owner_id, model_id, revision, dims, vector, content_hash, created_at)
                VALUES (?, ?, 'm', 1, 1, x'00', 'h', ?)
                """, arguments: [table, id, created.addingTimeInterval(60)])
        }
    }
    #expect(try store.pendingSourceCount(identity: nil) == 0)
    #expect(try store.pendingSourceCount(identity: EmbeddingIdentity(modelID: "m", revision: 1)) == 0)
    #expect(try store.pendingSourceCount(identity: EmbeddingIdentity(modelID: "m", revision: 2)) == 3)
    // A fact confirmed after its vector was made, and an invalidated fact (never pending).
    try db.writer.write { d in
        try d.execute(sql: "UPDATE wiki_facts SET last_confirmed_at = ?", arguments: [created.addingTimeInterval(120)])
    }
    #expect(try store.pendingSourceCount(identity: nil) == 1)
    try db.writer.write { d in try d.execute(sql: "UPDATE wiki_facts SET invalid_at = ?", arguments: [created]) }
    #expect(try store.pendingSourceCount(identity: nil) == 0)
}

@Test func pendingSourcesShareTheCountPredicate() throws {
    let db = try AppDatabase.inMemory()
    let created = date(2026, 11, 20, 12)
    try db.writer.write { d in
        for key in ["2026-11-18", "2026-11-19"] {
            try d.execute(sql: """
                INSERT INTO chronicle (level, period_key, period_start, period_end, summary, generated_at)
                VALUES ('day', ?, ?, ?, 's', ?)
                """, arguments: [key, created, created, created])
        }
        try d.execute(sql: """
            INSERT INTO wiki_pages (slug, type, title, first_seen, last_seen, updated_at)
            VALUES ('p', 'topic', 'P', ?, ?, ?)
            """, arguments: [created, created, created])
        try d.execute(sql: """
            INSERT INTO embeddings (owner_table, owner_id, model_id, revision, dims, vector, content_hash, created_at)
            VALUES ('chronicle', 1, 'm', 1, 1, x'00', 'h', ?), ('wiki_pages', 1, 'm', 2, 1, x'00', 'h', ?)
            """, arguments: [created.addingTimeInterval(60), created.addingTimeInterval(60)])
    }
    let store = EmbeddingStore(db)
    // Revision ignored: only chronicle 2 has no vector.
    #expect(try store.pendingSources(identity: nil, limit: 10) == [.init(ownerTable: "chronicle", ownerID: 2)])
    // Identity (m, 2): chronicle 1 has revision 1, chronicle 2 has none; the page matches.
    let identity = EmbeddingIdentity(modelID: "m", revision: 2)
    let pending = try store.pendingSources(identity: identity, limit: 10)
    #expect(pending == [.init(ownerTable: "chronicle", ownerID: 1), .init(ownerTable: "chronicle", ownerID: 2)])
    #expect(pending.count == (try store.pendingSourceCount(identity: identity)))
    #expect(try store.pendingSourceCount(identity: nil) == 1)
    #expect(try store.pendingSources(identity: identity, limit: 1).count == 1)
    // Another model makes the page pending too, across tables.
    let other = EmbeddingIdentity(modelID: "x", revision: 1)
    #expect(try store.pendingSources(identity: other, limit: 10).count == (try store.pendingSourceCount(identity: other)))
    #expect(try store.pendingSourceCount(identity: other) == 3)
}
