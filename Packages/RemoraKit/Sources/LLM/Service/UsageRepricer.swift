import Foundation
import Storage
import os

/// Fills in the cost of calls that were recorded before their model had a price, once the price
/// table knows it. Only fills `est_cost_usd IS NULL` rows, so a recorded cost is never rewritten.
public enum UsageRepricer {
    private static let log = Logger(subsystem: "dev.remora", category: "llm")

    /// Returns how many rows were priced. Stops when none is left or a batch prices nothing (the
    /// remaining rows have an unknown backend or model, so asking again would loop forever).
    public static func backfill(store: LLMCallStore, prices: PriceTable, batch: Int = 500) throws -> Int {
        var updated = 0
        while true {
            let rows = try store.unpricedWithTokens(limit: batch)
            var pricedInBatch = 0
            for row in rows {
                guard let id = row.id, let backend = LLMBackend(rawValue: row.backend) else { continue }
                let usage = LLMUsage(inputTokens: row.inputTokens, cachedInputTokens: row.cachedInputTokens,
                                     outputTokens: row.outputTokens, reasoningTokens: row.reasoningTokens)
                guard let usd = prices.cost(model: row.model, usage: usage, backend: backend) else { continue }
                try store.setCostIfUnpriced(id: id, usd: usd)
                pricedInBatch += 1
            }
            updated += pricedInBatch
            if pricedInBatch == 0 || rows.count < batch { break }
        }
        if updated > 0 { log.info("repriced \(updated, privacy: .public) calls") }
        return updated
    }
}
