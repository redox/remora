import Foundation
import LLM
import LLMTestSupport
import Storage
import Testing
@testable import Dictation

private let usage = LLMUsage(inputTokens: 10, cachedInputTokens: 0, outputTokens: 5, reasoningTokens: 0)
private let spikeSlugs = ["gpt-6.2-sol", "gpt-6.2-astra", "gpt-6.1-terra", "gpt-6.1-sol", "gpt-6-astra", "gpt-6-sol", "gpt-6-luna"]
private let spike = spikeSlugs.map { ModelInfo(slug: $0, displayName: $0) }
private let frRaw = "euh donc je pense que euh on peut y aller demain"

private struct Env {
    var db: AppDatabase
    var siwc: FakeLLMClient
    var onDevice: FakeLLMClient
    var cleaner: DictationCleaner
}

private func env(onDevice: [FakeLLMClient.Step] = [], siwc: [FakeLLMClient.Step] = [.delta("SIWC"), .complete(usage)],
                 available: OnDeviceAvailability = .available, timeout: Duration = .seconds(8),
                 tier: Tier? = .onDevice) throws -> Env {
    let db = try AppDatabase.inMemory()
    let od = FakeLLMClient(backend: .onDevice, script: onDevice), cloud = FakeLLMClient(script: siwc)
    let config = RoutingConfig(jobTiers: tier.map { [.dictationCleanup: $0] } ?? [:])
    let svc = LLMService(siwc: cloud, onDevice: od, onDeviceAvailability: { available }, calls: LLMCallStore(db),
                         routing: { config }, catalog: { spike }, prices: { .empty }, retryDelay: .zero)
    return Env(db: db, siwc: cloud, onDevice: od, cleaner: DictationCleaner(llm: svc, timeout: timeout))
}

@Test func cleanedTextIsUsedAndAccounted() async throws {
    let e = try env(onDevice: [.delta("Je pense qu'on peut y aller demain."), .complete(usage)])
    let out = try await e.cleaner.process(raw: frRaw, locale: .fr, cleanupEnabled: true, cloudAllowed: false)
    #expect(out == .init(text: "Je pense qu'on peut y aller demain.", cleaned: true, notice: nil))
    let rows = try LLMCallStore(e.db).recent(limit: 5)
    #expect(rows.count == 1 && rows[0].jobType == "dictation_cleanup" && rows[0].backend == "on_device")
    // The prompt holds the transcript only.
    #expect(e.onDevice.requests.count == 1)
    #expect(e.onDevice.requests[0].input == [.user("<transcript>\n\(frRaw)\n</transcript>")])
}

@Test func cloudRouteUsesSmallTierWithCloudAllowed() async throws {
    let e = try env(siwc: [.delta("Je pense qu'on peut y aller demain."), .complete(usage)], tier: nil)
    let out = try await e.cleaner.process(raw: frRaw, locale: .fr, cleanupEnabled: true, cloudAllowed: true)
    #expect(out.cleaned && e.onDevice.requests.isEmpty && e.siwc.requests.count == 1)
    #expect(e.siwc.requests[0].model == "gpt-6-luna")
}

@Test func shortTranscriptSkipsLLM() async throws {
    let e = try env()
    let out = try await e.cleaner.process(raw: "Oui, merci.", locale: .fr, cleanupEnabled: true, cloudAllowed: true)
    #expect(out == .init(text: "Oui, merci.", cleaned: false, notice: nil))
    #expect(e.onDevice.requests.isEmpty && e.siwc.requests.isEmpty)
}

@Test func cleanupOffReturnsRaw() async throws {
    let e = try env()
    let out = try await e.cleaner.process(raw: frRaw, locale: .fr, cleanupEnabled: false, cloudAllowed: true)
    #expect(out == .init(text: frRaw, cleaned: false, notice: nil))
    #expect(e.onDevice.requests.isEmpty && e.siwc.requests.isEmpty)
}

@Test func llmErrorFallsBackToRawWithNotice() async throws {
    let e = try env(siwc: [.fail(.notSignedIn)], available: .unavailable("off"))
    let out = try await e.cleaner.process(raw: frRaw, locale: .fr, cleanupEnabled: true, cloudAllowed: true)
    #expect(out == .init(text: frRaw, cleaned: false, notice: .cleanupSkipped))
}

@Test func timeoutFallsBackToRaw() async throws {
    let e = try env(onDevice: [.hang], timeout: .milliseconds(50))
    let start = ContinuousClock.now
    let out = try await e.cleaner.process(raw: frRaw, locale: .fr, cleanupEnabled: true, cloudAllowed: false)
    #expect(out == .init(text: frRaw, cleaned: false, notice: .cleanupSkipped))
    #expect(ContinuousClock.now - start < .seconds(1))
}

@Test func cloudNotAllowedNeverHitsSIWC() async throws {
    let e = try env(available: .unavailable("off"))
    let out = try await e.cleaner.process(raw: frRaw, locale: .fr, cleanupEnabled: true, cloudAllowed: false)
    #expect(out == .init(text: frRaw, cleaned: false, notice: .cleanupSkipped))
    #expect(e.siwc.requests.isEmpty)
}

@Test func productionRoutingWithoutOnDeviceNeverHitsSIWC() async throws {
    let e = try env(available: .unavailable("off"), tier: nil)
    let out = try await e.cleaner.process(raw: frRaw, locale: .fr, cleanupEnabled: true, cloudAllowed: false)
    #expect(out == .init(text: frRaw, cleaned: false, notice: .cleanupSkipped))
    #expect(e.siwc.requests.isEmpty && e.onDevice.requests.isEmpty)
}

@Test func onDeviceFailureNeverFallsBackToCloudWhenNotAllowed() async throws {
    let e = try env(onDevice: [.fail(.onDeviceUnavailable(reason: "too large"))])
    let out = try await e.cleaner.process(raw: frRaw, locale: .fr, cleanupEnabled: true, cloudAllowed: false)
    #expect(out == .init(text: frRaw, cleaned: false, notice: .cleanupSkipped))
    #expect(e.siwc.requests.isEmpty)
}

@Test func guardRejectionFallsBackToRaw() async throws {
    let e = try env(onDevice: [.delta("I think we can go there tomorrow without any problem at all."), .complete(usage)])
    let out = try await e.cleaner.process(raw: "je pense qu'on peut y aller demain sans aucun problème", locale: .fr,
                                          cleanupEnabled: true, cloudAllowed: false)
    #expect(out.cleaned == false && out.notice == .cleanupSkipped)
    #expect(out.text == "je pense qu'on peut y aller demain sans aucun problème")
}

@Test func cancellationThrows() async throws {
    let e = try env(onDevice: [.hang])
    let cleaner = e.cleaner
    let task = Task { () async throws -> CleanupOutcome in
        try await cleaner.process(raw: frRaw, locale: .fr, cleanupEnabled: true, cloudAllowed: false)
    }
    try await Task.sleep(for: .milliseconds(100))
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}
