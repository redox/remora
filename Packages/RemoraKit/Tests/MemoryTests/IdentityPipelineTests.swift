import Foundation
import GRDB
import LLM
import LLMTestSupport
import Redaction
import Storage
import Testing
@testable import Memory

private let idNow = t0
private let idUsage = LLMUsage(inputTokens: 10, cachedInputTokens: 0, outputTokens: 5, reasoningTokens: 0)
private final class IDBox: @unchecked Sendable { var db: AppDatabase? }

private func identityJSON(_ text: String) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: ["identity": text]), as: UTF8.self)
}

private let llmIdentity = "### Role & focus\nProduct designer\n### Projects\nOslo offsite"

private struct IDEnv {
    var db: AppDatabase
    var fake: FakeLLMClient
    var pipeline: IdentityPipeline
}

private func idEnv(_ fake: FakeLLMClient? = nil, db: AppDatabase? = nil) throws -> IDEnv {
    let fake = fake ?? .bySchema(["identity": identityJSON(llmIdentity)])
    let db = try db ?? AppDatabase.inMemory()
    let llm = LLMService(siwc: fake, onDevice: FakeLLMClient(backend: .onDevice, script: []),
                         onDeviceAvailability: { .available }, calls: LLMCallStore(db),
                         routing: { RoutingConfig() }, catalog: { lunaCatalog }, prices: { .empty },
                         now: { idNow }, retryDelay: .zero)
    return IDEnv(db: db, fake: fake, pipeline: IdentityPipeline(db: db, llm: llm, calendar: paris))
}

private func idContext(generation: Int = 0, cloudAllowed: Bool = true) -> JobContext {
    JobContext(now: idNow, calendar: paris, generation: generation, cloudAllowed: cloudAllowed, language: .en)
}

private func idJob(_ db: AppDatabase) throws -> Job {
    let week = PeriodKey.interval(.week, containing: idNow, calendar: paris)
    let key = PeriodKey.key(.week, for: idNow, calendar: paris)
    try JobStore(db).enqueue([JobSpec(kind: .identity, periodKey: key, periodStart: week.start, periodEnd: week.end,
                                      notBefore: idNow)], now: idNow)
    return try require(try JobStore(db).job(kind: .identity, periodKey: key))
}

private func day(_ db: AppDatabase, _ d: Int, _ summary: String, snapshots: [Int64] = []) throws {
    let start = date(2026, 11, d)
    _ = try db.writer.write { c in
        try ChronicleStore(db).upsert(Chronicle(
            level: .day, periodKey: PeriodKey.key(.day, for: start, calendar: paris), periodStart: start,
            periodEnd: date(2026, 11, d + 1), summary: summary, snapshotIDs: snapshots, generatedAt: start), in: c)
    }
}

private func output(_ db: AppDatabase, original: String = "I wrote this myself", result: String = "Remora output",
                    mode: InlineMode = .full, outcome: InlineOutcome? = .kept, finalText: String? = nil,
                    app: String = "Notes", bundle: String? = "com.apple.Notes", surface: String = "com.apple.Notes",
                    at: Date = date(2026, 11, 19, 10)) throws {
    _ = try InlineOutputStore(db).insert(InlineOutput(createdAt: at, mode: mode, app: app, bundleID: bundle, surface: surface,
                                                      original: original, result: result, outcome: outcome, finalText: finalText))
}

private func text(_ r: LLMRequest) -> String {
    r.input.map { item -> String in if case .user(let s) = item { return s }; return "" }.joined(separator: "\n")
}

@Test func identityIsStoredAsLLMRevisionWithCallAndArtifact() async throws {
    let env = try idEnv()
    try day(env.db, 19, "Prepared the Oslo offsite.")
    #expect(try await env.pipeline.run(try idJob(env.db), context: idContext()) == .done)
    let current = try #require(try IdentityStore(env.db).current())
    #expect(current.source == .llm && current.body == llmIdentity)
    let call = try #require(try LLMCallStore(env.db).recent(limit: 5).first)
    #expect(call.jobType == "identity" && call.model == "gpt-6.1-terra")
    #expect(current.llmCallID == call.id && call.artifactTable == "identity" && call.artifactID == current.id)
}

@Test func identityPromptCarriesSamplesAndRules() async throws {
    let env = try idEnv()
    try day(env.db, 19, "Prepared the Oslo offsite.")
    _ = try IdentityStore(env.db).saveUserEdit(llmIdentity + "\nMy name is Kévin", at: date(2026, 11, 1))
    try output(env.db, original: "Hello team, here is my draft", mode: .full)
    try output(env.db, original: "ignored original", mode: .edit)
    try output(env.db, original: "sel", mode: .selection, outcome: .edited, finalText: "I always write like this")
    _ = try await env.pipeline.run(try idJob(env.db), context: idContext())
    let t = text(try #require(env.fake.requests.first))
    #expect(t.contains("<samples>") && t.contains("keep these lines verbatim") && t.contains("My name is Kévin"))
    #expect(t.contains("Hello team, here is my draft") && t.contains("I always write like this"))
    #expect(!t.contains("ignored original") && !t.contains("Remora output"))
    #expect(t.contains("Prepared the Oslo offsite."))
}

@Test func userEditsSurviveTwoLLMRounds() async throws {
    let env = try idEnv()
    try day(env.db, 19, "Prepared the Oslo offsite.")
    _ = try IdentityStore(env.db).saveUserEdit(llmIdentity + "\nMy name is Kévin", at: date(2026, 11, 1))
    #expect(try await env.pipeline.run(try idJob(env.db), context: idContext()) == .done)
    let first = try #require(try IdentityStore(env.db).current())
    #expect(first.source == .llm && first.body.contains("### Notes from you\nMy name is Kévin"))
    // Round two: the model again omits the line (it also sees the Notes section; the fake ignores it).
    #expect(try await env.pipeline.run(try idJob(env.db), context: idContext()) == .done)
    let second = try #require(try IdentityStore(env.db).current())
    #expect(second.id != first.id)
    #expect(second.body.components(separatedBy: "My name is Kévin").count == 2)
    #expect(second.body.components(separatedBy: "### Notes from you").count == 2)
}

@Test func aLineTheUserRemovedIsNeverReintroduced() async throws {
    let env = try idEnv(.bySchema(["identity": identityJSON(llmIdentity + "\nLikes golf")]))
    try day(env.db, 19, "Prepared the Oslo offsite.")
    try await env.db.writer.write { d in _ = try IdentityStore(env.db).insertLLM(llmIdentity + "\nLikes golf", llmCallID: nil, at: date(2026, 11, 1), in: d) }
    _ = try IdentityStore(env.db).saveUserEdit(llmIdentity, at: date(2026, 11, 2))
    _ = try await env.pipeline.run(try idJob(env.db), context: idContext())
    let body = try #require(try IdentityStore(env.db).current()?.body)
    #expect(!body.contains("Likes golf") && body.contains("Oslo offsite"))
    let t = text(try #require(env.fake.requests.first))
    #expect(t.contains("do not reintroduce") && t.contains("Likes golf"))
}

@Test func userEditMadeDuringTheCallWinsOverTheModelOutput() async throws {
    let box = IDBox()
    let fake = FakeLLMClient(backend: .siwc) { _ in
        // The user removes "Oslo offsite" and adds a line while the model is working.
        _ = try? IdentityStore(box.db!).saveUserEdit("### Role & focus\nProduct designer\n### Projects\nMy own line", at: date(2026, 11, 20, 13))
        return [.delta(identityJSON(llmIdentity)), .complete(idUsage)]
    }
    let env = try idEnv(fake)
    box.db = env.db
    try day(env.db, 19, "Prepared the Oslo offsite.")
    try await env.db.writer.write { d in _ = try IdentityStore(env.db).insertLLM(llmIdentity, llmCallID: nil, at: date(2026, 11, 1), in: d) }
    _ = try await env.pipeline.run(try idJob(env.db), context: idContext())
    let body = try #require(try IdentityStore(env.db).current()?.body)
    #expect(body.contains("My own line"))
    #expect(!body.contains("Oslo offsite"))
}

@Test func identityOutputIsRedacted() async throws {
    let env = try idEnv(.bySchema(["identity": identityJSON("### Role & focus\nKey AKIAIOSFODNN7EXAMPLE")]))
    try day(env.db, 19, "Prepared the Oslo offsite.")
    _ = try await env.pipeline.run(try idJob(env.db), context: idContext())
    #expect(try IdentityStore(env.db).current()?.body.contains("AKIAIOSFODNN7EXAMPLE") == false)
}

@Test func excludedSourcesNeverReachTheIdentityPrompt() async throws {
    let env = try idEnv()
    let notes = try SnapshotStore(env.db).insert(Snapshot(capturedAt: date(2026, 11, 19, 9), app: "Notes",
        bundleID: "com.apple.Notes", windowTitle: "n", text: "x", contentHash: "h1", source: .ax))
    try day(env.db, 18, "Private notes day", snapshots: [try #require(notes.id)])
    try day(env.db, 19, "Prepared the Oslo offsite.")
    try output(env.db, original: "Secret draft from Notes", app: "Notes", bundle: "com.apple.Notes")
    try output(env.db, original: "Draft from Mail", app: "Mail", bundle: "com.apple.mail", surface: "com.apple.mail")
    try output(env.db, original: "Draft from a site", app: "Safari", bundle: "com.apple.Safari", surface: "private.example.com")
    try ExclusionStore(env.db).add("app:Notes")
    try ExclusionStore(env.db).add("private.example.com")
    _ = try await env.pipeline.run(try idJob(env.db), context: idContext())
    let t = text(try #require(env.fake.requests.first))
    #expect(!t.contains("Private notes day") && !t.contains("Secret draft from Notes") && !t.contains("Draft from a site"))
    #expect(t.contains("Draft from Mail") && t.contains("Prepared the Oslo offsite."))
}

@Test func identitySkippedWhenTheCloudIsDeniedOrThereIsNoEvidence() async throws {
    let env = try idEnv()
    try day(env.db, 19, "Prepared the Oslo offsite.")
    #expect(try await env.pipeline.run(try idJob(env.db), context: idContext(cloudAllowed: false)) == .skipped("cloud_denied"))
    let empty = try idEnv()
    #expect(try await empty.pipeline.run(try idJob(empty.db), context: idContext()) == .skipped("no_evidence"))
    #expect(env.fake.requests.isEmpty && empty.fake.requests.isEmpty)
}

@Test func staleGenerationDiscardsTheIdentity() async throws {
    let env = try idEnv()
    try day(env.db, 19, "Prepared the Oslo offsite.")
    await #expect(throws: DataGeneration.Stale.self) {
        _ = try await env.pipeline.run(try idJob(env.db), context: idContext(generation: 5))
    }
    #expect(try IdentityStore(env.db).current() == nil)
}
