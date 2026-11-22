import Foundation
import Testing
import Storage
@testable import Memory

private struct StubPlanner: JobPlanning {
    var plan: JobPlan
    func plan(_ s: SchedulerSignals) throws -> JobPlan { plan }
}

private struct ThrowingPlanner: JobPlanning {
    struct Boom: Error {}
    func plan(_ s: SchedulerSignals) throws -> JobPlan { throw Boom() }
}

/// One busy hour two hours before t0, so the real `JobPlanner` advances its watermark.
private struct OneBusyHour: PlannerData {
    func hourStats(from: Date, to: Date, calendar: Calendar) throws -> [HourStat] {
        let start = t0.addingTimeInterval(-7_200)
        guard start >= from, start.addingTimeInterval(3_600) <= to else { return [] }
        return [HourStat(hour: DateInterval(start: start, end: start.addingTimeInterval(3_600)),
                         focusSeconds: 3_000, snapshotCount: 3)]
    }
    func newestSnapshotAt() throws -> Date? { nil }
    func dirtyWikiPages(minMentions: Int) throws -> Int { 0 }
    func pendingEmbeddings() throws -> Int { 0 }
    func inlineOutputsSince(_ d: Date?) throws -> Int { 0 }
    func dayChroniclesSince(_ d: Date?) throws -> Int { 0 }
    func lastIdentityAt() throws -> Date? { nil }
    func dirtyChronicles() throws -> [(ChronicleLevel, String)] { [] }
}

private func spec(_ kind: JobKind, _ key: String) -> JobSpec { JobSpec(kind: kind, periodKey: key, notBefore: t0) }

@Test func compositeConcatenatesSpecsAndRequeuesInOrder() throws {
    let a = StubPlanner(plan: JobPlan(specs: [spec(.morningBrief, "2026-11-20")],
                                      requeues: [JobRef(kind: .dayRollup, periodKey: "2026-11-19")]))
    let b = StubPlanner(plan: JobPlan(specs: [spec(.nudgeScan, "2026-11-20T14:00"), spec(.eveningWrap, "2026-11-20")],
                                      requeues: [JobRef(kind: .weekRollup, periodKey: "2026-W47")]))
    let plan = try CompositePlanner([a, b]).plan(signals())
    #expect(plan.specs.map(\.kind) == [.morningBrief, .nudgeScan, .eveningWrap])
    #expect(plan.requeues.map(\.kind) == [.dayRollup, .weekRollup])
    #expect(plan.watermark == nil)
    #expect(try CompositePlanner([]).plan(signals()) == JobPlan())
}

@Test func compositeSkipsAThrowingPlanner() throws {
    let ok = StubPlanner(plan: JobPlan(specs: [spec(.morningBrief, "2026-11-20")]))
    let plan = try CompositePlanner([ThrowingPlanner(), ok, ThrowingPlanner()]).plan(signals())
    #expect(plan.specs.map(\.kind) == [.morningBrief])
}

/// Addendum B.9: only `JobPlanner` owns `memory.plannerWatermark`; another planner's watermark is ignored.
@Test func compositeTakesTheWatermarkOnlyFromJobPlanner() throws {
    let db = try AppDatabase.inMemory()
    let memory = JobPlanner(db: db, data: OneBusyHour(), calendar: paris)
    let alone = try memory.plan(signals())
    let watermark = try #require(alone.watermark)

    let rogue = StubPlanner(plan: JobPlan(specs: [spec(.nudgeScan, "slot")], watermark: t0.addingTimeInterval(99_999)))
    for planners in [[rogue, memory], [memory, rogue]] as [[any JobPlanning]] {
        let plan = try CompositePlanner(planners).plan(signals())
        #expect(plan.watermark == watermark)
        #expect(plan.specs.count == alone.specs.count + 1)
    }
    #expect(try CompositePlanner([rogue]).plan(signals()).watermark == nil)
    // A throwing JobPlanner contributes nothing, its watermark included.
    #expect(try CompositePlanner([ThrowingPlanner(), rogue]).plan(signals()).specs.map(\.kind) == [.nudgeScan])
}
