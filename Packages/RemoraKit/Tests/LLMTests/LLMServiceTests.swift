import Foundation
import LLMTestSupport
import Storage
import Synchronization
import Testing
@testable import LLM

private let spike = spikeSlugs.map { ModelInfo(slug: $0, displayName: $0) }
private let usage = LLMUsage(inputTokens: 100, cachedInputTokens: 0, outputTokens: 5, reasoningTokens: 0)
private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private struct Env {
    var db: AppDatabase
    var settings: SettingsStore
    var svc: LLMService
}

private func env(siwc: FakeLLMClient, onDevice: FakeLLMClient = FakeLLMClient(backend: .onDevice, script: []),
                 available: OnDeviceAvailability = .available, config: RoutingConfig = RoutingConfig(jobTiers: [.queryExpansion: .onDevice]),
                 prices: PriceTable = .empty) throws -> Env {
    let db = try AppDatabase.inMemory()
    let settings = SettingsStore(db)
    let svc = LLMService(siwc: siwc, onDevice: onDevice, onDeviceAvailability: { available }, calls: LLMCallStore(db),
                         routing: { config }, catalog: { spike }, prices: { prices }, now: { t0 },
                         settings: settings, retryDelay: .zero)
    return Env(db: db, settings: settings, svc: svc)
}

private func rows(_ e: Env) throws -> [LLMCall] { try LLMCallStore(e.db).calls(since: .distantPast, limit: 20).reversed() }

@Test func completedCallWritesRow() async throws {
    let e = try env(siwc: FakeLLMClient(script: [.delta("Bon"), .delta("jour"), .complete(usage)]))
    let r = try await e.svc.complete(.rewrite, instructions: "i", input: [.user("x")])
    #expect(r.text == "Bonjour")
    let all = try rows(e)
    #expect(all.count == 1 && r.callID == all[0].id)
    let row = all[0]
    #expect(row.status == .completed && row.backend == "siwc" && row.model == "gpt-6.1-terra" && row.jobType == "rewrite")
    #expect(row.reasoningEffort == "low" && row.inputTokens == 100 && row.outputTokens == 5 && row.estCostUSD == nil)
}

@Test func priceTableFillsCost() async throws {
    let prices = PriceTable(models: ["gpt-6.1-terra": ModelPrice(inputPer1M: 10, outputPer1M: 20)])
    let e = try env(siwc: FakeLLMClient(script: [.complete(usage)]), prices: prices)
    _ = try await e.svc.complete(.rewrite, instructions: "i", input: [])
    let cost = try rows(e)[0].estCostUSD!
    #expect(abs(cost - (100 * 10 + 5 * 20) / 1e6) < 1e-12)
}

@Test func chatOmitsReasoningInRequestAndRow() async throws {
    let fake = FakeLLMClient(script: [.complete(usage)])
    let e = try env(siwc: fake)
    _ = try await e.svc.complete(.chat, instructions: "i", input: [.user("x")])
    let row = try rows(e)[0]
    #expect(fake.requests[0].reasoning == nil && row.reasoningEffort == nil)
}

@Test func midStreamLimitRecordsLimitRow() async throws {
    let e = try env(siwc: FakeLLMClient(script: [.delta("Par"), .fail(.usageLimit)]))
    await #expect(throws: LLMError.usageLimit) { try await e.svc.complete(.rewrite, instructions: "i", input: []) }
    let row = try rows(e)[0]
    #expect(row.status == .limit && row.errorCode == "usage_limit")
    #expect(await e.svc.lastLimitAt() == t0)
    let stored = try e.settings.value(Date.self, forKey: LLMService.lastLimitKey)
    #expect(stored == t0)
}

@Test func partialOutputIsNeverReturned() async throws {
    let e = try env(siwc: FakeLLMClient(script: [.delta("Par"), .fail(.streamEndedEarly)]))
    await #expect(throws: LLMError.streamEndedEarly) { try await e.svc.complete(.rewrite, instructions: "i", input: []) }
}

@Test func cancelledCallRecorded() async throws {
    let fake = FakeLLMClient(script: [.hang])
    let e = try env(siwc: fake)
    let svc = e.svc
    let task = Task { try await svc.complete(.rewrite, instructions: "i", input: []) }
    while fake.requests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
    task.cancel()
    await #expect(throws: LLMError.cancelled) { try await task.value }
    let all = try rows(e)
    #expect(all.count == 1 && all[0].status == .cancelled)
}

@Test func retryableErrorRetriesOnceThenSurfaces() async throws {
    let fake = FakeLLMClient(scripts: [[.fail(.temporarilyUnavailable(code: nil))], [.fail(.temporarilyUnavailable(code: nil))], [.complete(usage)]])
    let e = try env(siwc: fake)
    await #expect(throws: LLMError.temporarilyUnavailable(code: nil)) { try await e.svc.complete(.rewrite, instructions: "i", input: []) }
    let n = try rows(e).count
    #expect(fake.requests.count == 2 && n == 2)
}

@Test func retrySucceedsAndWritesARowPerAttempt() async throws {
    let fake = FakeLLMClient(scripts: [[.delta("x"), .fail(.transport(code: -1005))], [.delta("ok"), .complete(usage)]])
    let e = try env(siwc: fake)
    let r = try await e.svc.complete(.rewrite, instructions: "i", input: [])
    #expect(r.text == "ok")
    let statuses = try rows(e).map(\.status)
    #expect(statuses == [.failed, .completed])
}

@Test func noRetryAfterOutputWasDelivered() async throws {
    let fake = FakeLLMClient(scripts: [[.delta("x"), .fail(.transport(code: -1005))], [.complete(usage)]])
    let e = try env(siwc: fake)
    let seen = Mutex("")
    await #expect(throws: LLMError.transport(code: -1005)) {
        try await e.svc.complete(.rewrite, instructions: "i", input: [], onDelta: { d in seen.withLock { $0 += d } })
    }
    #expect(seen.withLock { $0 } == "x" && fake.requests.count == 1)
}

@Test func nonRetryableErrorIsNotRetried() async throws {
    let fake = FakeLLMClient(scripts: [[.fail(.forbidden)], [.complete(usage)]])
    let e = try env(siwc: fake)
    await #expect(throws: LLMError.forbidden) { try await e.svc.complete(.rewrite, instructions: "i", input: []) }
    #expect(fake.requests.count == 1)
}

private let schemaFormat = TextFormat.jsonSchema(name: "n", schema: .object(["type": .string("object"), "required": .array([.string("a")])]), strict: true)

@Test func onDeviceSchemaFailureFallsBackToSmall() async throws {
    let od = FakeLLMClient(backend: .onDevice, script: [.delta("not json"), .complete(usage)])
    let siwc = FakeLLMClient(script: [.delta(#"{"a":1}"#), .complete(usage)])
    let e = try env(siwc: siwc, onDevice: od)
    let r = try await e.svc.complete(.queryExpansion, instructions: "i", input: [.user("x")], format: schemaFormat)
    #expect(r.text == #"{"a":1}"# && r.route.backend == .siwc)
    let all = try rows(e)
    #expect(all.count == 2 && all[0].backend == "on_device" && all[0].status == .failed && all[0].errorCode == "schema_mismatch")
    #expect(all[1].backend == "siwc" && all[1].model == "gpt-6-luna" && all[1].status == .completed)
    #expect(od.requests[0].reasoning == nil && siwc.requests[0].reasoning == .low)
}

@Test func onDeviceUnavailableThrownByClientFallsBack() async throws {
    let od = FakeLLMClient(backend: .onDevice, script: [.fail(.onDeviceUnavailable(reason: "big"))])
    let siwc = FakeLLMClient(script: [.delta("ok"), .complete(usage)])
    let e = try env(siwc: siwc, onDevice: od)
    let r = try await e.svc.complete(.queryExpansion, instructions: "i", input: [])
    let n = try rows(e).count
    #expect(r.text == "ok" && n == 2)
}

@Test func unavailableOnDeviceGoesStraightToSmall() async throws {
    let od = FakeLLMClient(backend: .onDevice, script: [])
    let e = try env(siwc: FakeLLMClient(script: [.complete(usage)]), onDevice: od, available: .unavailable("off"))
    let r = try await e.svc.complete(.queryExpansion, instructions: "i", input: [])
    let n = try rows(e).count
    #expect(od.requests.isEmpty && r.route.backend == .siwc && n == 1)
}

@Test func onDeviceRowHasEstimatedTokensAndZeroCost() async throws {
    let od = FakeLLMClient(backend: .onDevice, script: [.delta("hello"), .complete(LLMUsage(inputTokens: 30, cachedInputTokens: 0, outputTokens: 2, reasoningTokens: 0))])
    let e = try env(siwc: FakeLLMClient(script: []), onDevice: od)
    let r = try await e.svc.complete(.queryExpansion, instructions: "i", input: [])
    let row = try rows(e)[0]
    #expect(r.route.backend == .onDevice && row.model == FoundationModelsClient.modelID)
    #expect(row.inputTokens == 30 && row.outputTokens == 2 && row.estCostUSD == 0 && row.reasoningEffort == nil)
}

@Test func toolsSkipTheOnDeviceRoute() async throws {
    let od = FakeLLMClient(backend: .onDevice, script: [])
    let siwc = FakeLLMClient(script: [.functionCall(FunctionCall(callID: "c", name: "n", arguments: "{}")), .complete(usage)])
    let e = try env(siwc: siwc, onDevice: od)
    let tool = FunctionTool(name: "n", description: "d", parameters: .object([:]))
    let r = try await e.svc.complete(.queryExpansion, instructions: "i", input: [], tools: [tool])
    #expect(od.requests.isEmpty && r.functionCalls.map(\.name) == ["n"])
}

@Test func jsonSchemaTextIsDeliveredOnceAfterValidation() async throws {
    let siwc = FakeLLMClient(script: [.delta(#"{"a""#), .delta(":1}"), .complete(usage)])
    let e = try env(siwc: siwc)
    let seen = Mutex<[String]>([])
    _ = try await e.svc.complete(.rewrite, instructions: "i", input: [], format: schemaFormat, onDelta: { d in seen.withLock { $0.append(d) } })
    #expect(seen.withLock { $0 } == [#"{"a":1}"#])
}

@Test func cloudNotAllowedUsesOnDeviceOnly() async throws {
    let od = FakeLLMClient(backend: .onDevice, script: [.delta("ok"), .complete(usage)])
    let siwc = FakeLLMClient(script: [.complete(usage)])
    let e = try env(siwc: siwc, onDevice: od)
    let r = try await e.svc.complete(.rewrite, instructions: "i", input: [], cloudAllowed: false)
    #expect(r.route.backend == .onDevice && siwc.requests.isEmpty)
}

@Test func cloudNotAllowedFailsClosedWhenOnDeviceUnavailable() async throws {
    let siwc = FakeLLMClient(script: [.complete(usage)])
    let e = try env(siwc: siwc, available: .unavailable("off"))
    do { _ = try await e.svc.complete(.rewrite, instructions: "i", input: [], cloudAllowed: false); Issue.record("no throw") }
    catch { guard case LLMError.onDeviceUnavailable = error else { Issue.record("\(error)"); return } }
    let n = try rows(e).count
    #expect(siwc.requests.isEmpty && n == 0)
}

@Test func cloudNotAllowedFailureCarriesTheOnDeviceReason() async throws {
    let siwc = FakeLLMClient(script: [.complete(usage)])
    let e = try env(siwc: siwc, available: .unavailable("Apple Intelligence is turned off."))
    await #expect(throws: LLMError.onDeviceUnavailable(reason: "Apple Intelligence is turned off.")) {
        try await e.svc.complete(.rewrite, instructions: "i", input: [], cloudAllowed: false)
    }
    #expect(siwc.requests.isEmpty)
}

@Test func onDeviceFailureWithCloudNotAllowedDoesNotFallBackToCloud() async throws {
    let od = FakeLLMClient(backend: .onDevice, script: [.fail(.onDeviceUnavailable(reason: "big"))])
    let siwc = FakeLLMClient(script: [.complete(usage)])
    let e = try env(siwc: siwc, onDevice: od)
    await #expect(throws: LLMError.onDeviceUnavailable(reason: "big")) {
        try await e.svc.complete(.rewrite, instructions: "i", input: [], cloudAllowed: false)
    }
    #expect(siwc.requests.isEmpty)
}

@Test func retryBudgetIsPerCallNotPerRoute() async throws {
    // on-device fails retryably, retries once, then falls... the second route must not get a fresh retry.
    let od = FakeLLMClient(backend: .onDevice, scripts: [[.fail(.temporarilyUnavailable(code: nil))], [.fail(.schemaMismatch)]])
    let siwc = FakeLLMClient(scripts: [[.fail(.temporarilyUnavailable(code: nil))], [.complete(usage)]])
    let e = try env(siwc: siwc, onDevice: od)
    await #expect(throws: LLMError.temporarilyUnavailable(code: nil)) {
        try await e.svc.complete(.queryExpansion, instructions: "i", input: [])
    }
    #expect(od.requests.count == 2 && siwc.requests.count == 1)
}

@Test func unusedCallRecordsNullCost() async throws {
    let prices = PriceTable(models: ["gpt-6.1-terra": ModelPrice(inputPer1M: 10, outputPer1M: 20)])
    let e = try env(siwc: FakeLLMClient(script: [.fail(.forbidden)]), prices: prices)
    await #expect(throws: LLMError.forbidden) { try await e.svc.complete(.rewrite, instructions: "i", input: []) }
    #expect(try rows(e)[0].estCostUSD == nil)
}

@Test func cloudNotAllowedWithToolsFailsClosed() async throws {
    let siwc = FakeLLMClient(script: [.complete(usage)])
    let od = FakeLLMClient(backend: .onDevice, script: [.complete(usage)])
    let e = try env(siwc: siwc, onDevice: od)
    let tool = FunctionTool(name: "n", description: "d", parameters: .object([:]))
    do { _ = try await e.svc.complete(.rewrite, instructions: "i", input: [], tools: [tool], cloudAllowed: false); Issue.record("no throw") }
    catch { guard case LLMError.onDeviceUnavailable = error else { Issue.record("\(error)"); return } }
    let n = try rows(e).count
    #expect(siwc.requests.isEmpty && od.requests.isEmpty && n == 0)
}

@Test func cancelledAfterPartialRecordsCancelled() async throws {
    let fake = FakeLLMClient(script: [.delta("par"), .hang])
    let e = try env(siwc: fake)
    let svc = e.svc
    let seen = Mutex("")
    let task = Task { try await svc.complete(.rewrite, instructions: "i", input: [], onDelta: { d in seen.withLock { $0 += d } }) }
    while seen.withLock({ $0.isEmpty }) { try await Task.sleep(for: .milliseconds(5)) }
    task.cancel()
    await #expect(throws: LLMError.cancelled) { try await task.value }
    let all = try rows(e)
    #expect(all.count == 1 && all[0].status == .cancelled && all[0].errorCode == "cancelled")
}

@Test func cloudNotAllowedFiltersRoutes() async throws {
    let siwc = FakeLLMClient(script: [.complete(usage)])
    let e = try env(siwc: siwc, available: .unavailable("off"), config: RoutingConfig(jobTiers: [.dictationCleanup: .onDevice]))
    await #expect(throws: LLMError.onDeviceUnavailable(reason: "off")) {
        try await e.svc.complete(.dictationCleanup, instructions: "i", input: [.user("x")], cloudAllowed: false)
    }
    let n = try rows(e).count
    #expect(siwc.requests.isEmpty && n == 0)
}
