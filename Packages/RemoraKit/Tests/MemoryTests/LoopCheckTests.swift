import Embeddings
import Foundation
import GRDB
import LLM
import LLMTestSupport
import Storage
import Testing
@testable import Memory

// Open-loop checks (job type `evidenceCheck`) and the shared compaction test environment.

/// Saturday 2026-11-21 03:30 in Paris: the nightly compaction.
let cpNow = date(2026, 11, 21, 3, 30)

struct CompactionEnv {
    var db: AppDatabase
    var fake: FakeLLMClient
    var loopCheck: LoopCheck
    var compaction: CompactionPipeline
    var digest: DigestPipeline
}

func compactionEnv(_ fake: FakeLLMClient = .bySchema([:]), db: AppDatabase? = nil, dbURL: URL? = nil,
                   embedder: any Embedder = HashingEmbedder()) throws -> CompactionEnv {
    let db = try db ?? AppDatabase.inMemory()
    let llm = LLMService(siwc: fake, onDevice: FakeLLMClient(backend: .onDevice, script: []),
                         onDeviceAvailability: { .available }, calls: LLMCallStore(db),
                         routing: { RoutingConfig() }, catalog: { lunaCatalog }, prices: { .empty },
                         now: { cpNow }, retryDelay: .zero)
    let digest = DigestPipeline(db: db, llm: llm, identity: IdentityStore(db), calendar: paris)
    return CompactionEnv(db: db, fake: fake, loopCheck: LoopCheck(db: db, llm: llm, calendar: paris, redactor: .init()),
                         compaction: CompactionPipeline(db: db, dbURL: dbURL, llm: llm, embedder: embedder,
                                                        digest: digest, calendar: paris),
                         digest: digest)
}

func compactionContext(generation: Int = 0, cloudAllowed: Bool = true, now: Date = cpNow) -> JobContext {
    JobContext(now: now, calendar: paris, generation: generation, cloudAllowed: cloudAllowed, language: .en)
}

func loopJSON(done: Bool, confidence: Double, evidence: Int, quote: String) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: [
        "done": done, "confidence": confidence, "evidence": evidence, "quote": quote,
    ] as [String: Any]), as: UTF8.self)
}

@discardableResult
func seedSnapshot(_ db: AppDatabase, _ text: String, at: Date, app: String = "Mail", bundleID: String? = "com.apple.mail",
                  title: String? = "Inbox") throws -> Snapshot {
    try SnapshotStore(db).insert(Snapshot(capturedAt: at, app: app, bundleID: bundleID, windowTitle: title, text: text,
                                          contentHash: "h-\(at.timeIntervalSince1970)-\(text.hashValue)", source: .ax))
}

@discardableResult
func seedFlag(_ db: AppDatabase, _ kind: FlagKind = .commitment, _ text: String, owner: FlagOwner = .user,
              person: String = "", project: String = "", created: Date, lastSeen: Date? = nil, due: Date? = nil,
              checked: Date? = nil, ids: [Int64] = [], status: FlagStatus = .open) throws -> SalientFlag {
    try db.writer.write { d in
        var f = SalientFlag(kind: kind, text: text, owner: owner, person: person, project: project, dueAt: due,
                            status: status, confidence: 0.8, quote: "", snapshotIDs: ids,
                            dedupeKey: SalientFlagStore.dedupeKey(kind: kind, text: text, person: person),
                            createdAt: created, lastSeenAt: lastSeen ?? created, checkedAt: checked)
        try f.insert(d)
        return f
    }
}

func flagRow(_ db: AppDatabase, _ id: Int64?) throws -> SalientFlag? {
    try db.reader.read { try SalientFlag.fetchOne($0, key: id) }
}

private let deckText = """
    To: Marc Dupont
    Subject: Oslo offsite deck
    Here is the Oslo offsite deck, attached: deck-oslo-v3.key
    """

private func deckFlag(_ db: AppDatabase) throws -> SalientFlag {
    try seedFlag(db, .commitment, "Send Marc the Oslo offsite deck", person: "Marc Dupont", project: "Oslo offsite",
                 created: cpNow.addingTimeInterval(-2 * 86_400))
}

@Test func loopClosedOnlyWithVerifiedQuote() async throws {
    // A quote that is not in the cited snapshot never closes the loop.
    let planted = try compactionEnv(.bySchema(["loop_check": loopJSON(
        done: true, confidence: 0.9, evidence: 1, quote: "I already sent the deck to Marc yesterday")]))
    let flag = try deckFlag(planted.db)
    let sent = try seedSnapshot(planted.db, deckText, at: cpNow.addingTimeInterval(-86_400))
    let verdict = try await planted.loopCheck.check(flag, context: compactionContext())
    #expect(verdict.status == .open && verdict.closeSnapshotID == nil)
    let report = try await planted.compaction.compact(context: compactionContext())
    #expect(report.loopsChecked == 1 && report.loopsClosed == 0)
    let stillOpen = try #require(try flagRow(planted.db, flag.id))
    #expect(stillOpen.status == .open && stillOpen.closeSnapshotIDs.isEmpty && stillOpen.checkedAt == cpNow)

    // The same answer with a quote copied from the snapshot closes it, citing that snapshot.
    let real = try compactionEnv(.bySchema(["loop_check": loopJSON(
        done: true, confidence: 0.9, evidence: 1, quote: "“here is the Oslo offsite deck”")]))
    let flag2 = try deckFlag(real.db)
    let sent2 = try seedSnapshot(real.db, deckText, at: cpNow.addingTimeInterval(-86_400))
    let verdict2 = try await real.loopCheck.check(flag2, context: compactionContext())
    #expect(verdict2.status == .done && verdict2.closeSnapshotID == sent2.id)
    let report2 = try await real.compaction.compact(context: compactionContext())
    #expect(report2.loopsClosed == 1)
    let closed = try #require(try flagRow(real.db, flag2.id))
    let sentID = try #require(sent2.id)
    #expect(closed.status == .done && closed.closeSnapshotIDs == [sentID] && closed.closedAt == cpNow)
    #expect(closed.confidence == 0.9)
    #expect(sent.id != nil)
}

@Test func lowConfidenceStaysOpen() async throws {
    let env = try compactionEnv(.bySchema(["loop_check": loopJSON(
        done: true, confidence: 0.6, evidence: 1, quote: "Here is the Oslo offsite deck")]))
    let flag = try deckFlag(env.db)
    try seedSnapshot(env.db, deckText, at: cpNow.addingTimeInterval(-86_400))
    let verdict = try await env.loopCheck.check(flag, context: compactionContext())
    #expect(verdict.status == .open && verdict.closeSnapshotID == nil)
    #expect(verdict.confidence == 0.6)
    _ = try await env.compaction.compact(context: compactionContext())
    #expect(try flagRow(env.db, flag.id)?.status == .open)
}

@Test func notDoneNeverCloses() async throws {
    let env = try compactionEnv(.bySchema(["loop_check": loopJSON(
        done: false, confidence: 0.95, evidence: 1, quote: "Here is the Oslo offsite deck")]))
    let flag = try deckFlag(env.db)
    try seedSnapshot(env.db, deckText, at: cpNow.addingTimeInterval(-86_400))
    #expect(try await env.loopCheck.check(flag, context: compactionContext()).status == .open)
}

@Test func quoteMustBeInTheCitedSnapshot() async throws {
    // The quote is in snapshot 2, but the answer cites snapshot 1.
    let env = try compactionEnv(.bySchema(["loop_check": loopJSON(
        done: true, confidence: 0.9, evidence: 1, quote: "Here is the Oslo offsite deck")]))
    let flag = try deckFlag(env.db)
    try seedSnapshot(env.db, "Marc Dupont: any news on the Oslo offsite deck?", at: cpNow.addingTimeInterval(-90_000))
    try seedSnapshot(env.db, deckText, at: cpNow.addingTimeInterval(-86_400))
    #expect(try await env.loopCheck.check(flag, context: compactionContext()).status == .open)

    let cites2 = try compactionEnv(.bySchema(["loop_check": loopJSON(
        done: true, confidence: 0.9, evidence: 2, quote: "Here is the Oslo offsite deck")]), db: env.db)
    #expect(try await cites2.loopCheck.check(flag, context: compactionContext()).status == .done)
}

@Test func evidenceIsNewerThanTheFlagAndPolicyFiltered() async throws {
    let env = try compactionEnv(.bySchema(["loop_check": loopJSON(done: false, confidence: 0, evidence: 0, quote: "")]))
    let flag = try deckFlag(env.db)
    // Older than the flag: not evidence of closing it.
    try seedSnapshot(env.db, "Draft: Oslo offsite deck for Marc Dupont (old)", at: cpNow.addingTimeInterval(-3 * 86_400))
    // From an app excluded now.
    try seedSnapshot(env.db, "Slack: Marc Dupont, the Oslo offsite deck is in #general", at: cpNow.addingTimeInterval(-3_600),
                     app: "Slack", bundleID: "com.tinyspeck.slackmacgap", title: "#general")
    try ExclusionStore(env.db).add("app:Slack")
    // No allowed evidence: no call at all, and the flag stays open.
    let verdict = try await env.loopCheck.check(flag, context: compactionContext())
    #expect(verdict.status == .open && env.fake.requests.isEmpty)

    try seedSnapshot(env.db, deckText, at: cpNow.addingTimeInterval(-86_400))
    _ = try await env.loopCheck.check(flag, context: compactionContext())
    let request = try #require(env.fake.requests.first)
    let text = allInput([request])
    #expect(text.contains("deck-oslo-v3.key"))
    #expect(!text.contains("(old)") && !text.contains("#general"))
    #expect(schemaName(request) == "loop_check")
    #expect(text.contains(PipelinePrompt.untrusted))
}

@Test func evidenceIsCappedAt12000Chars() async throws {
    let env = try compactionEnv(.bySchema(["loop_check": loopJSON(done: false, confidence: 0, evidence: 0, quote: "")]))
    let flag = try deckFlag(env.db)
    for i in 0..<10 {
        try seedSnapshot(env.db, "Oslo offsite deck for Marc Dupont, version \(i). " + String(repeating: "lorem ipsum ", count: 300),
                         at: cpNow.addingTimeInterval(-Double(i + 1) * 3_600))
    }
    _ = try await env.loopCheck.check(flag, context: compactionContext())
    let request = try #require(env.fake.requests.first)
    let bodies = request.input.compactMap { item -> String? in
        if case .user(let s) = item, s.contains("<snapshot") { return s }
        return nil
    }
    let block = try #require(bodies.first)
    // ~36,000 chars of matches; the snapshot bodies are fitted to 12,000 (headers are extra).
    #expect(block.count < 12_000 + 1_500)
    #expect(block.contains("<snapshot n=\"1\">"))
}

@Test func cloudDeniedLoopCheckMakesNoCall() async throws {
    let env = try compactionEnv(.bySchema(["loop_check": loopJSON(
        done: true, confidence: 0.9, evidence: 1, quote: "Here is the Oslo offsite deck")]))
    let flag = try deckFlag(env.db)
    try seedSnapshot(env.db, deckText, at: cpNow.addingTimeInterval(-86_400))
    let verdict = try await env.loopCheck.check(flag, context: compactionContext(cloudAllowed: false))
    #expect(verdict.status == .open && env.fake.requests.isEmpty)
}

/// Final review #3: a flag learned only from an app excluded since never reaches the loop-check
/// prompt, and does not use up the night's budget.
@Test func flagLearnedOnlyFromAnExcludedAppIsNeverChecked() async throws {
    let env = try compactionEnv(.bySchema(["loop_check": loopJSON(done: false, confidence: 0.2, evidence: 0, quote: "")]))
    let tg = try #require(try seedSnapshot(env.db, "Marc Dupont: send me the lodge contract", at: cpNow.addingTimeInterval(-3 * 86_400),
                                           app: "Telegram", bundleID: "ru.keepcoder.Telegram", title: "Marc").id)
    let mail = try #require(try seedSnapshot(env.db, "Marc Dupont: the deck please", at: cpNow.addingTimeInterval(-3 * 86_400)).id)
    let hidden = try seedFlag(env.db, .commitment, "Send Marc Dupont the Holmenkollen lodge contract", person: "Marc Dupont",
                              created: cpNow.addingTimeInterval(-2 * 86_400), ids: [tg])
    let visible = try seedFlag(env.db, .commitment, "Send Marc Dupont the deck", person: "Marc Dupont",
                               created: cpNow.addingTimeInterval(-2 * 86_400), ids: [mail])
    try seedSnapshot(env.db, "Marc Dupont: any news on the deck and the contract?", at: cpNow.addingTimeInterval(-86_400))
    try ExclusionStore(env.db).add("app:Telegram")

    let report = try await env.compaction.compact(context: compactionContext())

    #expect(report.loopsChecked == 1)
    #expect(env.fake.requests.filter { schemaName($0) == "loop_check" }.count == 1)
    let prompt = allInput(env.fake.requests.filter { schemaName($0) == "loop_check" })
    #expect(prompt.contains("Send Marc Dupont the deck"))
    #expect(!prompt.contains("Holmenkollen"))
    #expect(try flagRow(env.db, hidden.id)?.checkedAt == nil)
    #expect(try flagRow(env.db, visible.id)?.checkedAt == cpNow)
}
