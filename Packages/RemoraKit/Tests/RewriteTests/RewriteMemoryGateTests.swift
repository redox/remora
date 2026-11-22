import Capture
import Foundation
import LLM
import LLMTestSupport
import Retrieval
import Storage
import Synchronization
import Testing
@testable import Rewrite

// The rewrite gate decides whether memory may be used; the context then carries none at all in
// excluded, private, unverifiable and paused contexts (controller ruling, Task 12).

private let gt0 = Date(timeIntervalSince1970: 1_800_000_000)
private let gUsage = LLMUsage(inputTokens: 10, cachedInputTokens: 0, outputTokens: 2, reasoningTokens: 0)
private let gModels = ["gpt-6.1-terra", "gpt-6-luna"].map { ModelInfo(slug: $0, displayName: $0) }
private let memoryTags = ["<digest>", "<identity>", "<working_memory>", "<memory>", "<open_items>", "<related>",
                          "<recent>", "<style>"]

private final class CountingExpander: QueryExpander {
    private let count = Mutex(0)
    var calls: Int { count.withLock { $0 } }
    func expand(_ terms: [String], cloudAllowed: Bool, timeout: Duration) async -> [String] {
        count.withLock { $0 += 1 }
        return terms
    }
}

private func seededDB() throws -> AppDatabase {
    let db = try AppDatabase.inMemory()
    _ = try SnapshotStore(db).insert(Snapshot(capturedAt: gt0.addingTimeInterval(-120), app: "Notes", windowTitle: "Roadmap",
                                              text: "Roadmap review on Thursday", contentHash: "n", source: .ax))
    try db.writer.write { d in
        _ = try MemoryDigestStore(db).insert(MemoryDigest(body: "Digest about the roadmap", createdAt: gt0), in: d)
        try WorkingMemoryStore(db).merge([WorkingMemoryItem(text: "Roadmap item", kind: "topic", normKey: "", relevance: 0.9,
                                                            addedAt: gt0, lastSeenAt: gt0)], now: gt0, in: d)
        _ = try ChronicleStore(db).upsert(Chronicle(level: .hour, periodKey: "h", periodStart: gt0.addingTimeInterval(-7_200),
                                                    periodEnd: gt0.addingTimeInterval(-3_600), summary: "Roadmap review held",
                                                    generatedAt: gt0), in: d)
        _ = try SalientFlagStore.upsert(SalientFlag(kind: .todo, text: "Roadmap follow-up", owner: .user,
                                                    dueAt: gt0.addingTimeInterval(86_400), dedupeKey: "k",
                                                    createdAt: gt0, lastSeenAt: gt0), in: d)
    }
    try IdentityStore(db).saveUserEdit("Identity text", at: gt0)
    try StyleNoteStore(db).upsert(surface: "*", notes: "Style text", llmCallID: nil, at: gt0)
    return db
}

struct RewriteGateCase: CustomStringConvertible, Sendable {
    var description: String
    var context: WindowContext
    var fieldBundleID: String
    var policy: CapturePolicy
    var paused: Bool
    var memoryExpected: Bool
}

let rewriteGateCases: [RewriteGateCase] = [
    RewriteGateCase(description: "capturable", context: WindowContext(app: "Mail", bundleID: "com.apple.mail", windowTitle: "Re: x"),
             fieldBundleID: "com.apple.mail", policy: CapturePolicy(userRules: []), paused: false, memoryExpected: true),
    RewriteGateCase(description: "paused", context: WindowContext(app: "Mail", bundleID: "com.apple.mail", windowTitle: "Re: x"),
             fieldBundleID: "com.apple.mail", policy: CapturePolicy(userRules: []), paused: true, memoryExpected: false),
    RewriteGateCase(description: "excluded", context: WindowContext(app: "Mail", bundleID: "com.apple.mail", windowTitle: "Re: x"),
             fieldBundleID: "com.apple.mail", policy: CapturePolicy(userRules: [ExclusionRule(pattern: "app:Mail")!]),
             paused: false, memoryExpected: false),
    RewriteGateCase(description: "private", context: WindowContext(app: "Safari", bundleID: "com.apple.Safari",
                                                            url: URL(string: "https://example.com"), isPrivateBrowsing: true),
             fieldBundleID: "com.apple.Safari", policy: CapturePolicy(userRules: []), paused: false, memoryExpected: false),
    RewriteGateCase(description: "unverifiable", context: WindowContext(app: "Safari", bundleID: "com.apple.Safari"),
             fieldBundleID: "com.apple.Safari", policy: CapturePolicy(userRules: []), paused: false, memoryExpected: false),
    RewriteGateCase(description: "rules unavailable", context: WindowContext(app: "Mail", bundleID: "com.apple.mail", windowTitle: "Re: x"),
             fieldBundleID: "com.apple.mail", policy: .denyAll, paused: false, memoryExpected: false),
]

@Test(arguments: rewriteGateCases)
func memoryContextFollowsTheRewriteGate(_ c: RewriteGateCase) async throws {
    guard case .proceed(let access) = RewriteFlow.gate(context: c.context, contextPID: 10, fieldPID: 10,
                                                       fieldBundleID: c.fieldBundleID, policy: c.policy,
                                                       paused: c.paused) else {
        Issue.record("refused"); return
    }
    #expect(access.memoryAllowed == c.memoryExpected)
    let db = try seededDB()
    let cloud = FakeLLMClient(backend: .siwc) { _ in [.delta("ok"), .complete(gUsage)] }
    let local = FakeLLMClient(backend: .onDevice) { _ in [.delta("ok"), .complete(gUsage)] }
    let llm = LLMService(siwc: cloud, onDevice: local, onDeviceAvailability: { .available }, calls: LLMCallStore(db),
                         routing: { RoutingConfig() }, catalog: { gModels }, prices: { .empty }, now: { gt0 },
                         retryDelay: .zero)
    let expander = CountingExpander()
    let engine = RewriteEngine(llm: llm, context: ContextAssembler(db: db, expander: expander),
                               outputs: InlineOutputStore(db), calls: LLMCallStore(db), now: { gt0 })
    // Built the way the app builds it (RewriteController.makeRequest).
    let r = RewriteRequest(mode: .full, fieldValue: "About the roadmap review", app: c.context.app,
                           bundleID: c.fieldBundleID, surface: c.fieldBundleID,
                           windowTitle: access.windowContextAllowed ? c.context.windowTitle : nil,
                           liveWindowText: access.windowContextAllowed ? "live window" : nil,
                           memoryAllowed: access.memoryAllowed, logAllowed: access.logAllowed,
                           cloudAllowed: access.cloudAllowed)
    _ = try await engine.rewrite(r)
    let request = try #require((cloud.requests + local.requests).first)
    let text = request.input.map { if case .user(let s) = $0 { s } else { "" } }.joined()
    if c.memoryExpected {
        for tag in ["<digest>", "<identity>", "<working_memory>", "<memory>", "<open_items>", "<style>"] {
            #expect(text.contains(tag), "\(tag) missing")
        }
        #expect(expander.calls == 1)
    } else {
        for tag in memoryTags { #expect(!text.contains(tag), "\(tag) leaked") }
        for word in ["Digest", "Identity", "Roadmap item", "Roadmap review held", "Roadmap follow-up", "Style text"] {
            #expect(!text.contains(word), "\(word) leaked")
        }
        #expect(expander.calls == 0)
    }
}
