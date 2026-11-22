import Foundation
import Testing
import Storage
@testable import Memory

@Test func budgetCountsOnlyBackgroundUncachedSIWCTokensSinceMidnight() throws {
    let db = try AppDatabase.inMemory()
    let calls = LLMCallStore(db)
    let today = t0.addingTimeInterval(-3_600)
    _ = try calls.insert(LLMCall(startedAt: today, durationMs: 1, backend: "siwc", model: "gpt-6-luna",
                                 jobType: "hour_chronicle", status: .completed, inputTokens: 100_000,
                                 cachedInputTokens: 40_000, outputTokens: 5_000))
    _ = try calls.insert(LLMCall(startedAt: today, durationMs: 1, backend: "siwc", model: "gpt-6",
                                 jobType: "rewrite", status: .completed, inputTokens: 50_000))
    _ = try calls.insert(LLMCall(startedAt: today, durationMs: 1, backend: "on_device", model: "apple",
                                 jobType: "hour_chronicle", status: .completed, inputTokens: 9_000))
    // Yesterday 23:59 local (Paris), i.e. before local midnight.
    _ = try calls.insert(LLMCall(startedAt: date(2026, 11, 19, 23, 59), durationMs: 1, backend: "siwc",
                                 model: "gpt-6", jobType: "day_rollup", status: .completed, inputTokens: 500_000))
    let gate = BudgetGate(db: db, calendar: paris)
    #expect(try gate.usedToday(now: t0) == 65_000)
    #expect(try BackgroundUsage.today(db, now: t0, calendar: paris) == 65_000)
    // The API-key route counts too; every foreground job type is excluded.
    try seedUsage(db, tokens: 1_000, backend: "api_key")
    for fg in BackgroundUsage.foregroundJobTypes { try seedUsage(db, tokens: 7_777, job: fg) }
    #expect(try gate.usedToday(now: t0) == 66_000)
}

@Test(arguments: [(600_000, BudgetLevel.soft), (749_999, .soft), (750_000, .exhausted), (100, .normal),
                  (599_999, .normal)])
func budgetLevels(used: Int, expected: BudgetLevel) throws {
    let db = try AppDatabase.inMemory()
    try seedUsage(db, tokens: used)
    let gate = BudgetGate(db: db, calendar: paris)
    #expect(try gate.usedToday(now: t0) == used)
    #expect(try gate.level(now: t0) == expected)
}

@Test func budgetLevelFollowsTheConfiguredBudget() throws {
    let db = try AppDatabase.inMemory()
    try MemorySettings(SettingsStore(db)).setDailyTokenBudget(1_000)
    try seedUsage(db, tokens: 800)
    #expect(try BudgetGate(db: db, calendar: paris).level(now: t0) == .soft)
}

@Test func softBudgetAllowsOnlyHourDayRollupWorkingMemoryAndBriefs() throws {
    let db = try AppDatabase.inMemory()
    let gate = BudgetGate(db: db, calendar: paris)
    for k in JobKind.allCases { #expect(try gate.allowsCloud(k, now: t0)) }
    try seedUsage(db, tokens: 700_000)
    let soft = JobKind.allCases.filter { (try? gate.allowsCloud($0, now: t0)) == true }
    #expect(Set(soft) == [.hour, .dayRollup, .workingMemory, .morningBrief, .eveningWrap, .digestRebuild])
    try seedUsage(db, tokens: 50_000)
    #expect(JobKind.allCases.allSatisfy { (try? gate.allowsCloud($0, now: t0)) == false })
}

@Test func runConditionsAndCloudUseMatchPinnedValues() {
    let anytime: Set<JobKind> = [.workingMemory, .timeLedger, .hour, .dayRollup, .weekRollup, .monthRollup,
                                 .yearRollup, .wikiRewrite, .morningBrief, .eveningWrap, .nudgeScan, .digestRebuild]
    for k in JobKind.allCases {
        let expected: RunCondition = anytime.contains(k) ? .anytime
            : [.styleNotes, .identity, .routineScan].contains(k) ? .idle(120) : .idleOnPower
        #expect(k.runCondition == expected, "\(k)")
        #expect(k.mayUseCloud == ![.timeLedger, .embeddings, .routineScan].contains(k), "\(k)")
    }
    #expect(RunCondition.idle(120).holds(signals(idle: 120)) && !RunCondition.idle(120).holds(signals(idle: 119)))
    #expect(RunCondition.idleOnPower.holds(signals(idle: 300, onPower: true)))
    #expect(!RunCondition.idleOnPower.holds(signals(idle: 300, onPower: false)))
    #expect(!RunCondition.idleOnPower.holds(signals(idle: 300, onPower: true, lowPower: true)))
    #expect(!RunCondition.idleOnPower.holds(signals(idle: 30, onPower: true)))
    #expect(RunCondition.anytime.holds(signals(idle: 0, onPower: false)))
}

/// F-8: working memory and compaction always pass; their cloud use needs memory on, an
/// account, no backoff and budget < 100 %. Other cloud kinds are denied with a reason.
@Test func gateDecisions() {
    func decide(_ k: JobKind, enabled: Bool = true, account: Bool = true, backoff: Bool = true,
                level: BudgetLevel = .normal) -> SchedulerGate.Decision {
        SchedulerGate.decide(k, memoryEnabled: enabled, accountReady: account, backoffAllows: backoff, level: level)
    }
    #expect(decide(.hour) == .run(cloudAllowed: true))
    #expect(decide(.hour, level: .soft) == .run(cloudAllowed: true))
    #expect(decide(.wikiRewrite, level: .soft) == .deny(.budget))
    #expect(decide(.hour, level: .exhausted) == .deny(.budget))
    #expect(decide(.hour, backoff: false) == .deny(.backoff))
    #expect(decide(.hour, account: false) == .deny(.account))
    #expect(decide(.hour, enabled: false) == .deny(.disabled))
    for k in [JobKind.compaction, .workingMemory] {
        #expect(decide(k) == .run(cloudAllowed: true))
        #expect(decide(k, level: .soft) == .run(cloudAllowed: true))
        #expect(decide(k, level: .exhausted) == .run(cloudAllowed: false))
        #expect(decide(k, backoff: false) == .run(cloudAllowed: false))
        #expect(decide(k, account: false) == .run(cloudAllowed: false))
    }
    #expect(decide(.compaction, enabled: false) == .run(cloudAllowed: false))
    #expect(decide(.workingMemory, enabled: false) == .deny(.disabled))
    #expect(decide(.timeLedger, enabled: false, account: false, backoff: false, level: .exhausted)
            == .run(cloudAllowed: false))
    #expect(decide(.embeddings, account: false, backoff: false, level: .exhausted) == .run(cloudAllowed: false))
    #expect(decide(.embeddings, enabled: false) == .deny(.disabled))
    // Addendum B.8: memory off denies the proactive kinds (no memory, no evidence).
    for k in [JobKind.morningBrief, .eveningWrap, .nudgeScan] {
        #expect(decide(k, enabled: false) == .deny(.disabled), "\(k)")
        #expect(decide(k) == .run(cloudAllowed: true), "\(k)")
    }
    #expect(decide(.morningBrief, level: .soft) == .run(cloudAllowed: true))
    #expect(decide(.nudgeScan, level: .soft) == .deny(.budget))
    #expect(decide(.eveningWrap, level: .exhausted) == .deny(.budget))
}

@Test func briefsAllowedUnderSoftBudget() throws {
    let db = try AppDatabase.inMemory()
    try seedUsage(db, tokens: 600_000)  // 80 % of the default 750 000
    let gate = BudgetGate(db: db, calendar: paris)
    #expect(try gate.level(now: t0) == .soft)
    #expect(try gate.allowsCloud(.morningBrief, now: t0))
    #expect(try gate.allowsCloud(.eveningWrap, now: t0))
    #expect(try !gate.allowsCloud(.nudgeScan, now: t0))
    for k in [JobKind.morningBrief, .eveningWrap, .nudgeScan] { #expect(k.mayUseCloud, "\(k)") }
}
