import Foundation
import GRDB
import LLM
import LLMTestSupport
import Storage
import Testing
@testable import Memory

private let stNow = t0
private let stUsage = LLMUsage(inputTokens: 10, cachedInputTokens: 0, outputTokens: 5, reasoningTokens: 0)
private final class STBox: @unchecked Sendable { var db: AppDatabase? }

private func rulesJSON(_ rules: [(String, String, String)]) -> String {
    let arr = rules.map { ["scope": $0.0, "kind": $0.1, "bullet": $0.2] }
    return String(decoding: try! JSONSerialization.data(withJSONObject: ["rules": arr]), as: UTF8.self)
}

private struct STEnv {
    var db: AppDatabase
    var fake: FakeLLMClient
    var pipeline: StylePipeline
}

private func stEnv(_ fake: FakeLLMClient? = nil, db: AppDatabase? = nil) throws -> STEnv {
    let fake = fake ?? .bySchema(["style_rules": rulesJSON([("this_surface", "tone", "Casual, first names only")])])
    let db = try db ?? AppDatabase.inMemory()
    let llm = LLMService(siwc: fake, onDevice: FakeLLMClient(backend: .onDevice, script: []),
                         onDeviceAvailability: { .available }, calls: LLMCallStore(db),
                         routing: { RoutingConfig() }, catalog: { lunaCatalog }, prices: { .empty },
                         now: { stNow }, retryDelay: .zero)
    return STEnv(db: db, fake: fake, pipeline: StylePipeline(db: db, llm: llm, calendar: paris))
}

private func stContext(generation: Int = 0, cloudAllowed: Bool = true) -> JobContext {
    JobContext(now: stNow, calendar: paris, generation: generation, cloudAllowed: cloudAllowed, language: .en)
}

private func stJob(_ db: AppDatabase) throws -> Job {
    let day = PeriodKey.interval(.day, containing: stNow, calendar: paris)
    let key = PeriodKey.key(.day, for: stNow, calendar: paris)
    try JobStore(db).enqueue([JobSpec(kind: .styleNotes, periodKey: key, periodStart: day.start, periodEnd: day.end,
                                      notBefore: stNow)], now: stNow)
    return try require(try JobStore(db).job(kind: .styleNotes, periodKey: key))
}

private func rewrite(_ db: AppDatabase, surface: String, count: Int, app: String = "Slack", bundle: String? = "com.slack",
                     original: String = "hey team", result: String = "Hello team!", outcome: InlineOutcome? = .edited,
                     finalText: String? = "hey team :)", start: Date = date(2026, 11, 19, 9)) throws {
    for i in 0..<count {
        _ = try InlineOutputStore(db).insert(InlineOutput(
            createdAt: start.addingTimeInterval(Double(i) * 60), mode: .selection, app: app, bundleID: bundle, surface: surface,
            original: original, result: result, outcome: outcome, finalText: finalText))
    }
}

private func text(_ r: LLMRequest) -> String {
    r.input.map { item -> String in if case .user(let s) = item { return s }; return "" }.joined(separator: "\n")
}

@Test func styleNeedsThreeOutputsPerSurface() async throws {
    let env = try stEnv()
    try rewrite(env.db, surface: "slack", count: 3)
    try rewrite(env.db, surface: "mail", count: 2, app: "Mail", bundle: "com.apple.mail")
    #expect(try await env.pipeline.run(try stJob(env.db), context: stContext()) == .done)
    #expect(env.fake.requests.count == 1)
    #expect(text(env.fake.requests[0]).contains("slack") && !text(env.fake.requests[0]).contains("mail"))
    #expect(try StyleNoteStore(env.db).note(for: "slack") == "- Casual, first names only\n")
    #expect(try StyleNoteStore(env.db).note(for: "mail") == nil)
}

@Test func allScopeRulesGoToStar() async throws {
    let env = try stEnv(.bySchema(["style_rules": rulesJSON([
        ("this_surface", "format", "Short paragraphs"), ("all", "lexical", "Never say synergy")])]))
    try rewrite(env.db, surface: "slack", count: 3)
    _ = try await env.pipeline.run(try stJob(env.db), context: stContext())
    #expect(try StyleNoteStore(env.db).note(for: "slack") == "- Short paragraphs\n")
    #expect(try StyleNoteStore(env.db).note(for: "*") == "- Never say synergy\n")
}

@Test func styleRunStoresCallAndAdvancesTheWatermark() async throws {
    let env = try stEnv()
    try rewrite(env.db, surface: "slack", count: 3)
    _ = try await env.pipeline.run(try stJob(env.db), context: stContext())
    let call = try #require(try LLMCallStore(env.db).calls(since: .distantPast, limit: 5).first)
    #expect(call.jobType == "style_consolidation" && call.model == "gpt-6.1-terra")
    #expect(try StyleNoteStore(env.db).row(for: "slack")?.llmCallID == call.id)
    let mark = try SettingsStore(env.db).value(Date.self, forKey: JobPlanner.lastStyleRunKey)
    #expect(mark == date(2026, 11, 19, 9, 2))
    // Nothing new: no second call.
    _ = try await env.pipeline.run(try stJob(env.db), context: stContext())
    #expect(env.fake.requests.count == 1)
}

@Test func styleBulletsAreRedactedCappedAndLimitedTo12() async throws {
    let many = (1...20).map { ("this_surface", "tone", "Distinct rule \($0) uniqueword\($0) AKIAIOSFODNN7EXAMPLE") }
        + [("all", "format", String(repeating: "long ", count: 60))]
    let env = try stEnv(.bySchema(["style_rules": rulesJSON(many)]))
    try rewrite(env.db, surface: "slack", count: 3)
    _ = try await env.pipeline.run(try stJob(env.db), context: stContext())
    let slack = StyleNotesMerge.bullets(try #require(try StyleNoteStore(env.db).note(for: "slack")))
    #expect(slack.count == 12 && slack.allSatisfy { $0.count <= 120 && !$0.contains("AKIAIOSFODNN7EXAMPLE") })
    let star = StyleNotesMerge.bullets(try #require(try StyleNoteStore(env.db).note(for: "*")))
    #expect(star.count == 1 && star[0].count <= 120)
}

@Test func excludedSurfacesAreNeverSentToTheModel() async throws {
    let env = try stEnv()
    try rewrite(env.db, surface: "com.apple.Notes", count: 3, app: "Notes", bundle: "com.apple.Notes", original: "secret notes draft")
    try rewrite(env.db, surface: "private.example.com", count: 3, app: "Safari", bundle: "com.apple.Safari", original: "secret site draft")
    try rewrite(env.db, surface: "slack", count: 3, original: "visible draft")
    try ExclusionStore(env.db).add("app:Notes")
    try ExclusionStore(env.db).add("private.example.com")
    _ = try await env.pipeline.run(try stJob(env.db), context: stContext())
    #expect(env.fake.requests.count == 1)
    let t = text(env.fake.requests[0])
    #expect(!t.contains("secret") && !t.contains("Notes") && !t.contains("private.example.com") && t.contains("visible draft"))
    #expect(try StyleNoteStore(env.db).note(for: "com.apple.Notes") == nil)
}

@Test func styleSkippedWhenTheCloudIsDenied() async throws {
    let env = try stEnv()
    try rewrite(env.db, surface: "slack", count: 3)
    #expect(try await env.pipeline.run(try stJob(env.db), context: stContext(cloudAllowed: false)) == .skipped("cloud_denied"))
    #expect(env.fake.requests.isEmpty)
}

@Test func userEditedNoteIsNeverOverwrittenByTheModelOnlyAppended() async throws {
    let env = try stEnv(.bySchema(["style_rules": rulesJSON([
        ("this_surface", "tone", "Casual, first names only"), ("this_surface", "format", "Use short paragraphs")])]))
    try rewrite(env.db, surface: "slack", count: 3)
    let long = "- " + String(repeating: "very long user bullet ", count: 12)
    let raw = "\(long)\nSome prose the user typed.\n- Casual, first names only please\n"
    try StyleNoteStore(env.db).upsert(surface: "slack", notes: raw, llmCallID: nil, at: date(2026, 11, 1))
    _ = try await env.pipeline.run(try stJob(env.db), context: stContext())
    let row = try #require(try StyleNoteStore(env.db).row(for: "slack"))
    #expect(row.notes == raw + "- Use short paragraphs\n" && row.llmCallID == nil)
}

@Test func nothingIsWrittenToAUserNoteWhenTheModelOnlyOffersNearDuplicates() async throws {
    let env = try stEnv()
    try rewrite(env.db, surface: "slack", count: 3)
    let raw = "Prose\n- Casual, first names only please"
    try StyleNoteStore(env.db).upsert(surface: "slack", notes: raw, llmCallID: nil, at: date(2026, 11, 1))
    _ = try await env.pipeline.run(try stJob(env.db), context: stContext())
    let row = try #require(try StyleNoteStore(env.db).row(for: "slack"))
    #expect(row.notes == raw && row.updatedAt == date(2026, 11, 1))
}

@Test func aSurfaceWithTwoOutputsInEachOfTwoRunsIsConsolidatedOnTheSecond() async throws {
    let env = try stEnv()
    try rewrite(env.db, surface: "slack", count: 2, start: date(2026, 11, 18, 9))
    #expect(try await env.pipeline.run(try stJob(env.db), context: stContext()) == .skipped("not_enough_outputs"))
    #expect(env.fake.requests.isEmpty)
    try rewrite(env.db, surface: "slack", count: 2, start: date(2026, 11, 19, 9))
    #expect(try await env.pipeline.run(try stJob(env.db), context: stContext()) == .done)
    #expect(env.fake.requests.count == 1)
    #expect(try StyleNoteStore(env.db).note(for: "slack") == "- Casual, first names only\n")
}

@Test func surfacesBeyondTheCapStayEligibleForTheNextRun() async throws {
    let env = try stEnv()
    for i in 1...7 { try rewrite(env.db, surface: "s\(i)", count: 3) }
    _ = try await env.pipeline.run(try stJob(env.db), context: stContext())
    #expect(env.fake.requests.count == StylePipeline.maxSurfaces)
    _ = try await env.pipeline.run(try stJob(env.db), context: stContext())
    #expect(env.fake.requests.count == StylePipeline.maxSurfaces + 1)
}

@Test func aSurfaceWhoseOutputDidNotDecodeStaysEligible() async throws {
    let env = try stEnv(.bySchema(["style_rules": "not json"]))
    try rewrite(env.db, surface: "slack", count: 3)
    await #expect(throws: MemoryError.self) { _ = try await env.pipeline.run(try stJob(env.db), context: stContext()) }
    await #expect(throws: MemoryError.self) { _ = try await env.pipeline.run(try stJob(env.db), context: stContext()) }
    #expect(env.fake.requests.count == 2)
}

@Test func userEditMadeDuringTheCallWins() async throws {
    let box = STBox()
    let fake = FakeLLMClient(backend: .siwc) { _ in
        try? StyleNoteStore(box.db!).upsert(surface: "slack", notes: "- Typed by the user\n", llmCallID: nil, at: date(2026, 11, 20, 13))
        return [.delta(rulesJSON([("this_surface", "tone", "Brand new rule")])), .complete(stUsage)]
    }
    let env = try stEnv(fake)
    box.db = env.db
    try rewrite(env.db, surface: "slack", count: 3)
    _ = try await env.pipeline.run(try stJob(env.db), context: stContext())
    let notes = StyleNotesMerge.bullets(try #require(try StyleNoteStore(env.db).note(for: "slack")))
    #expect(notes.contains("Typed by the user") && notes.contains("Brand new rule"))
}

@Test func staleGenerationDiscardsTheStyleNotes() async throws {
    let env = try stEnv()
    try rewrite(env.db, surface: "slack", count: 3)
    await #expect(throws: DataGeneration.Stale.self) {
        _ = try await env.pipeline.run(try stJob(env.db), context: stContext(generation: 5))
    }
    #expect(try StyleNoteStore(env.db).note(for: "slack") == nil)
}

@Test func invalidOutputForEverySurfaceFailsTheJob() async throws {
    let env = try stEnv(.bySchema(["style_rules": "not json"]))
    try rewrite(env.db, surface: "slack", count: 3)
    await #expect(throws: MemoryError.self) { _ = try await env.pipeline.run(try stJob(env.db), context: stContext()) }
}

/// Final review #17: when the model adds nothing for a surface, its outputs are still consumed, so
/// the next run does not send them again; the user's note stays byte-identical, `updated_at` too.
@Test func outputsTheModelAddedNothingForAreNotSentAgain() async throws {
    let env = try stEnv(.bySchema(["style_rules": rulesJSON([])]))
    try rewrite(env.db, surface: "slack", count: 3)
    try rewrite(env.db, surface: "mail", count: 3, app: "Mail", bundle: "com.apple.mail")
    let raw = "Prose\n- Casual, first names only please"
    try StyleNoteStore(env.db).upsert(surface: "slack", notes: raw, llmCallID: nil, at: date(2026, 11, 1))

    #expect(try await env.pipeline.run(try stJob(env.db), context: stContext()) == .done)
    #expect(env.fake.requests.count == 2)
    #expect(try await env.pipeline.run(try stJob(env.db), context: stContext()) == .skipped("not_enough_outputs"))
    #expect(env.fake.requests.count == 2)
    let row = try #require(try StyleNoteStore(env.db).row(for: "slack"))
    #expect(row.notes == raw && row.updatedAt == date(2026, 11, 1) && row.llmCallID == nil)
    #expect(try StyleNoteStore(env.db).row(for: "mail") == nil)

    // New outputs after the consumed ones make the surface eligible again.
    try rewrite(env.db, surface: "slack", count: 3, start: date(2026, 11, 19, 12))
    _ = try await env.pipeline.run(try stJob(env.db), context: stContext())
    #expect(env.fake.requests.count == 3)
}
