import Foundation
import Testing
@testable import LLM
@testable import Storage

private func call(model: String = "gpt-6-luna", backend: String = "siwc", input: Int = 1000,
                  output: Int = 100, cost: Double? = nil) -> LLMCall {
    LLMCall(startedAt: Date(timeIntervalSince1970: 1_700_000_000), durationMs: 10, backend: backend,
            model: model, jobType: "rewrite", status: .completed, inputTokens: input,
            outputTokens: output, estCostUSD: cost)
}

@Test func backfillFillsOnlyUnpricedRowsWithTokens() throws {
    let s = LLMCallStore(try .inMemory())
    let priced = try s.insert(call(cost: 1))
    let fill = try s.insert(call())
    let empty = try s.insert(call(input: 0, output: 0))
    let unknown = try s.insert(call(model: "no-such-model"))
    let badBackend = try s.insert(call(backend: "mystery"))

    let n = try UsageRepricer.backfill(store: s, prices: .builtIn)
    #expect(n == 1)
    let rows = Dictionary(uniqueKeysWithValues: try s.calls(since: .distantPast, limit: 10).map { ($0.id!, $0) })
    #expect(rows[priced.id!]?.estCostUSD == 1)
    let expected = PriceTable.builtIn.cost(model: "gpt-6-luna",
        usage: LLMUsage(inputTokens: 1000, cachedInputTokens: 0, outputTokens: 100, reasoningTokens: 0),
        backend: .siwc)
    #expect(rows[fill.id!]?.estCostUSD == expected && expected != nil)
    #expect(rows[empty.id!]?.estCostUSD == nil)
    #expect(rows[unknown.id!]?.estCostUSD == nil)
    #expect(rows[badBackend.id!]?.estCostUSD == nil)
}

@Test func backfillStopsWhenNothingCanBePriced() throws {
    let s = LLMCallStore(try .inMemory())
    for _ in 0..<5 { _ = try s.insert(call(model: "no-such-model")) }
    #expect(try UsageRepricer.backfill(store: s, prices: .builtIn, batch: 2) == 0)
}

@Test func backfillWorksThroughSeveralBatches() throws {
    let s = LLMCallStore(try .inMemory())
    for _ in 0..<5 { _ = try s.insert(call()) }
    #expect(try UsageRepricer.backfill(store: s, prices: .builtIn, batch: 2) == 5)
    #expect(try s.unpricedWithTokens(limit: 10).isEmpty)
}

@Test func unpriceableRowsDoNotStarvePriceableOnesAfterThem() throws {
    let s = LLMCallStore(try .inMemory())
    for _ in 0..<3 { _ = try s.insert(call(model: "no-such-model")) }
    for _ in 0..<2 { _ = try s.insert(call()) }
    #expect(try UsageRepricer.backfill(store: s, prices: .builtIn, batch: 2) == 2)
}
