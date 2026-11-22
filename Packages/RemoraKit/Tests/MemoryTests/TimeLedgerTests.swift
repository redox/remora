import Capture
import Foundation
import GRDB
import Storage
import Testing
@testable import Memory

private let h14 = DateInterval(start: date(2026, 11, 20, 14), end: date(2026, 11, 20, 15))

private func event(_ app: String, domain: String? = nil, title: String? = nil, _ from: Date, _ to: Date) -> ActivityEvent {
    ActivityEvent(app: app, windowTitle: title, domain: domain, startedAt: from, endedAt: to)
}

private let rule = TimeRule(id: 1, project: "Remora", domain: "github.com", createdAt: t0)
private let oslo = ProjectShare(name: "Oslo", apps: ["Mail"], share: 0.5)

@Test func ledgerClipsAndAttributes() {
    let events = [event("Xcode", date(2026, 11, 20, 13, 50), date(2026, 11, 20, 14, 20)),
                  event("Safari", domain: "github.com", date(2026, 11, 20, 14, 20), date(2026, 11, 20, 14, 50))]
    let rows = TimeLedgerBuilder.rows(events: events, hour: h14, rules: [rule], attribution: [oslo])
    #expect(rows == [TimeLedgerRow(hourStart: h14.start, project: "Remora", app: "Safari", domain: "github.com", seconds: 1_800),
                     TimeLedgerRow(hourStart: h14.start, project: "Unassigned", app: "Xcode", domain: "", seconds: 1_200)])
}

@Test func ledgerSumsPerProjectAppAndDomain() {
    let events = [event("Mail", date(2026, 11, 20, 14, 0), date(2026, 11, 20, 14, 10)),
                  event("Mail", date(2026, 11, 20, 14, 30), date(2026, 11, 20, 14, 35)),
                  event("Safari", domain: "api.github.com", date(2026, 11, 20, 14, 40), date(2026, 11, 20, 15, 30)),
                  event("Notes", date(2026, 11, 20, 15, 0), date(2026, 11, 20, 15, 10))]
    let rows = TimeLedgerBuilder.rows(events: events, hour: h14, rules: [rule], attribution: [oslo])
    #expect(rows.map(\.project) == ["Oslo", "Remora"])
    #expect(rows.map(\.seconds) == [900, 1_200])
    #expect(rows.last?.domain == "api.github.com")
}

@Test func userRuleBeatsAttribution() {
    let rules = [TimeRule(id: 2, project: "Inbox zero", app: "mail", createdAt: t0),
                 TimeRule(id: 5, project: "Later rule", app: "Mail", createdAt: t0)]
    let rows = TimeLedgerBuilder.rows(events: [event("Mail", date(2026, 11, 20, 14), date(2026, 11, 20, 14, 30))],
                                      hour: h14, rules: rules.reversed(), attribution: [oslo])
    // The rule wins over the attribution, and the lowest id wins among rules.
    #expect(rows.map(\.project) == ["Inbox zero"])
}

@Test func timeRuleNeedsEveryFieldAndFoldsText() {
    let both = TimeRule(id: 1, project: "Remora", app: "Safari", domain: "github.com", createdAt: t0)
    #expect(TimeRuleMatcher.project(app: "Safari", domain: "www.kayak.fr", title: nil, rules: [both]) == nil)
    #expect(TimeRuleMatcher.project(app: "SAFARI", domain: "gist.github.com", title: nil, rules: [both]) == "Remora")
    #expect(TimeRuleMatcher.project(app: "Safari", domain: "notgithub.com", title: nil, rules: [both]) == nil)

    let title = TimeRule(id: 2, project: "CV", titleContains: "resume", createdAt: t0)
    #expect(TimeRuleMatcher.project(app: "Pages", domain: nil, title: "Mon Résumé — final", rules: [title]) == "CV")
    #expect(TimeRuleMatcher.project(app: "Pages", domain: nil, title: nil, rules: [title]) == nil)

    let empty = TimeRule(id: 3, project: "Everything", app: " ", createdAt: t0)
    #expect(TimeRuleMatcher.project(app: "Pages", domain: nil, title: "x", rules: [empty]) == nil)
}

// MARK: - Pipeline

private func ledgerRows(_ db: AppDatabase) throws -> [TimeLedgerRow] {
    try db.reader.read { d in
        try TimeLedgerRow.fetchAll(d, sql: "SELECT * FROM time_ledger ORDER BY hour_start, project, app, domain")
    }
}

private func ledgerJob(_ db: AppDatabase, _ hour: DateInterval = h14) throws -> Job {
    let key = PeriodKey.key(.hour, for: hour.start, calendar: paris)
    try JobStore(db).enqueue([JobSpec(kind: .timeLedger, periodKey: key, periodStart: hour.start, periodEnd: hour.end,
                                      notBefore: hour.end)], now: hour.end)
    return try require(try JobStore(db).job(kind: .timeLedger, periodKey: key))
}

private func ledgerContext(generation: Int = 0) -> JobContext {
    JobContext(now: h14.end.addingTimeInterval(600), calendar: paris, generation: generation, cloudAllowed: true,
               language: .en)
}

private func seedChronicle(_ db: AppDatabase, span: DateInterval, projects: [ProjectShare]) throws {
    try db.writer.write { d in
        _ = try ChronicleStore(db).upsert(Chronicle(
            level: .hour, periodKey: PeriodKey.key(.hour, for: span.start, calendar: paris), periodStart: span.start,
            periodEnd: span.end, summary: "s", metadata: .init(projects: projects), generatedAt: span.end), in: d)
    }
}

@Test func ledgerRerunIsIdempotent() async throws {
    let db = try AppDatabase.inMemory()
    try insertActivity(db, app: "Xcode", from: date(2026, 11, 20, 13, 50), seconds: 1_800)
    try insertActivity(db, app: "Mail", from: date(2026, 11, 20, 14, 30), seconds: 600)
    try seedChronicle(db, span: h14, projects: [oslo])
    let pipeline = TimeLedgerPipeline(db: db)
    let job = try ledgerJob(db)

    #expect(try await pipeline.run(job, context: ledgerContext()) == .done)
    let first = try ledgerRows(db)
    #expect(try await pipeline.run(job, context: ledgerContext()) == .done)
    #expect(try ledgerRows(db) == first)
    #expect(first == [TimeLedgerRow(hourStart: h14.start, project: "Oslo", app: "Mail", seconds: 600),
                      TimeLedgerRow(hourStart: h14.start, project: "Unassigned", app: "Xcode", seconds: 1_200)])

    // A user rule added later re-attributes the hour on the next run, replacing the rows.
    _ = try TimeLedgerStore(db).addRule(TimeRule(project: "Acme app", app: "Xcode", createdAt: t0))
    #expect(try await pipeline.run(job, context: ledgerContext()) == .done)
    #expect(try ledgerRows(db).map(\.project) == ["Acme app", "Oslo"])
    #expect(try ledgerRows(db).map(\.seconds).reduce(0, +) == 1_800)
}

@Test func ledgerAttributesAMergedSparseSpanByInterval() async throws {
    // F-32: a sparse span 14:00–17:00 is keyed by its first hour; the 15:00 hour is inside it.
    let db = try AppDatabase.inMemory()
    try seedChronicle(db, span: DateInterval(start: date(2026, 11, 20, 14), end: date(2026, 11, 20, 17)), projects: [oslo])
    try insertActivity(db, app: "Mail", from: date(2026, 11, 20, 15, 10), seconds: 120)
    let h15 = DateInterval(start: date(2026, 11, 20, 15), end: date(2026, 11, 20, 16))
    #expect(try await TimeLedgerPipeline(db: db).run(try ledgerJob(db, h15), context: ledgerContext()) == .done)
    #expect(try ledgerRows(db) == [TimeLedgerRow(hourStart: h15.start, project: "Oslo", app: "Mail", seconds: 120)])
}

@Test func ledgerWithoutChronicleIsUnassignedAndWriteIsGenerationChecked() async throws {
    let db = try AppDatabase.inMemory()
    try insertActivity(db, app: "Mail", from: date(2026, 11, 20, 14, 10), seconds: 120)
    let pipeline = TimeLedgerPipeline(db: db)
    await #expect(throws: DataGeneration.Stale.self) {
        try await pipeline.run(try ledgerJob(db), context: ledgerContext(generation: 9))
    }
    #expect(try ledgerRows(db).isEmpty)
    #expect(try await pipeline.run(try ledgerJob(db), context: ledgerContext()) == .done)
    #expect(try ledgerRows(db).map(\.project) == ["Unassigned"])
}

@Test func ledgerRowPolicyJudgesAppNameAndDomain() throws {
    let policy = CapturePolicy(userRules: ["app:Slack", "news.example.com"].compactMap(ExclusionRule.init(pattern:)))
    #expect(!SnapshotPolicy.allows(app: "Slack", domain: "", policy: policy))
    #expect(SnapshotPolicy.allows(app: "Mail", domain: "", policy: policy))
    #expect(!SnapshotPolicy.allows(app: "Safari", domain: "news.example.com", policy: policy))
    #expect(SnapshotPolicy.allows(app: "Safari", domain: "github.com", policy: policy))
    #expect(!SnapshotPolicy.allows(app: "Mail", domain: "", policy: .denyAll))
}
