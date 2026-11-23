import Foundation
import LLM
import LLMTestSupport
import Retrieval
import Storage
import Testing
@testable import Memory

// Query expansion (F-17 / F-30 / F-40): small tier by default; on-device only when the rewrite
// itself may not use the cloud; any error or timeout keeps the base terms.

private let qUsage = LLMUsage(inputTokens: 80, cachedInputTokens: 0, outputTokens: 20, reasoningTokens: 0)
private let qJSON = #"{"terms":["meeting","Réunion","meetings"]}"#

private struct QEnv {
    var db: AppDatabase
    var siwc: FakeLLMClient
    var onDevice: FakeLLMClient
    var expander: LLMQueryExpander
}

private func qEnv(siwc: FakeLLMClient = .bySchema(["query_terms": qJSON], usage: qUsage),
                  onDevice: FakeLLMClient = FakeLLMClient(backend: .onDevice) { _ in [.delta(qJSON), .complete(qUsage)] },
                  onDeviceAvailable: Bool = true) throws -> QEnv {
    let db = try AppDatabase.inMemory()
    let availability: OnDeviceAvailability = onDeviceAvailable ? .available : .unavailable("not ready")
    let llm = LLMService(siwc: siwc, onDevice: onDevice, onDeviceAvailability: { availability },
                         calls: LLMCallStore(db), routing: { RoutingConfig() }, catalog: { lunaCatalog },
                         prices: { .empty }, now: { t0 }, retryDelay: .zero)
    return QEnv(db: db, siwc: siwc, onDevice: onDevice, expander: LLMQueryExpander(llm: llm))
}

@Test func expansionUsesSmallTierByDefault() async throws {
    let env = try qEnv()
    let terms = await env.expander.expand(["réunion", "budget"], cloudAllowed: true, timeout: .seconds(30))
    #expect(terms == ["réunion", "budget", "meeting", "meetings"])
    #expect(env.siwc.requests.count == 1 && env.onDevice.requests.isEmpty)
    let request = try #require(env.siwc.requests.first)
    #expect(request.model == "gpt-6-luna")
    guard case .jsonSchema(let name, _, let strict) = request.format else { Issue.record("not a schema"); return }
    #expect(name == "query_terms" && strict)
    let text = request.input.map { if case .user(let s) = $0 { s } else { "" } }.joined()
    #expect(text.contains("<terms>") && text.contains("réunion"))
    #expect(request.instructions.contains("untrusted"))
    #expect(try LLMCallStore(env.db).calls(since: .distantPast, limit: 1).first?.jobType == "query_expansion")
}

@Test func expansionStaysOnDeviceWhenCloudDenied() async throws {
    let env = try qEnv()
    let terms = await env.expander.expand(["réunion"], cloudAllowed: false, timeout: .seconds(30))
    #expect(terms == ["réunion", "meeting", "meetings"])
    #expect(env.siwc.requests.isEmpty && env.onDevice.requests.count == 1)
    // On-device unavailable: fails closed, base terms, still no cloud.
    let off = try qEnv(onDeviceAvailable: false)
    #expect(await off.expander.expand(["réunion"], cloudAllowed: false, timeout: .seconds(30)) == ["réunion"])
    #expect(off.siwc.requests.isEmpty && off.onDevice.requests.isEmpty)
}

@Test func expansionErrorKeepsBaseTerms() async throws {
    let failing = try qEnv(siwc: FakeLLMClient(backend: .siwc) { _ in [.fail(.badRequest(code: "x", param: nil))] })
    #expect(await failing.expander.expand(["réunion"], cloudAllowed: true, timeout: .seconds(30)) == ["réunion"])
    let garbage = try qEnv(siwc: FakeLLMClient(backend: .siwc) { _ in [.delta("not json"), .complete(qUsage)] })
    #expect(await garbage.expander.expand(["réunion"], cloudAllowed: true, timeout: .seconds(30)) == ["réunion"])
}

@Test func expansionTimeoutKeepsBaseTerms() async throws {
    // A call that never answers: the injected short timeout returns the base terms (no wall-clock assert).
    let env = try qEnv(siwc: FakeLLMClient(backend: .siwc) { _ in [.hang] })
    #expect(await env.expander.expand(["réunion", "budget"], cloudAllowed: true, timeout: .milliseconds(20))
            == ["réunion", "budget"])
    #expect(env.siwc.requests.count == 1)
}

@Test func expansionAddsAtMostEightCleanTerms() async throws {
    let junk = ["Budget", "", "   ", "<b>tag</b>", String(repeating: "x", count: 80)] + (1...12).map { "synonym\($0)" }
    let json = try #require(String(data: try JSONEncoder().encode(["terms": junk]), encoding: .utf8))
    let env = try qEnv(siwc: .bySchema(["query_terms": json], usage: qUsage))
    let terms = await env.expander.expand(["budget"], cloudAllowed: true, timeout: .seconds(30))
    #expect(terms.first == "budget")
    #expect(terms.count == 1 + LLMQueryExpander.maxAdded && LLMQueryExpander.maxAdded == 8)
    #expect(terms.dropFirst().allSatisfy { !$0.isEmpty && $0.count <= LLMQueryExpander.maxTermChars && !$0.contains("<") })
    #expect(Set(terms).count == terms.count)
    // Nothing to expand: no call.
    #expect(await env.expander.expand([], cloudAllowed: true, timeout: .seconds(30)).isEmpty)
    #expect(env.siwc.requests.count == 1)
}
