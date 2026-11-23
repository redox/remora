import Foundation
import Storage
import os

/// Fills in the cost of calls that were recorded before their model had a price, once the price
/// table knows it. Only fills `est_cost_usd IS NULL` rows, so a recorded cost is never rewritten.
public enum UsageRepricer {
    private static let log = Logger(subsystem: "dev.remora", category: "llm")

    /// Returns how many rows were priced. Pages by id, so rows that can never be priced (unknown
    /// backend or model) are skipped once instead of hiding the priceable rows after them.
    public static func backfill(store: LLMCallStore, prices: PriceTable, batch: Int = 500) throws -> Int {
        var updated = 0
        var lastID: Int64 = 0
        while true {
            let rows = try store.unpricedWithTokens(limit: batch, afterID: lastID)
            guard let last = rows.last?.id else { break }
            lastID = last
            var costs: [(id: Int64, usd: Double)] = []
            for row in rows {
                guard let id = row.id, let backend = LLMBackend(rawValue: row.backend) else { continue }
                let usage = LLMUsage(inputTokens: row.inputTokens, cachedInputTokens: row.cachedInputTokens,
                                     outputTokens: row.outputTokens, reasoningTokens: row.reasoningTokens)
                guard let usd = prices.cost(model: row.model, usage: usage, backend: backend) else { continue }
                costs.append((id: id, usd: usd))
            }
            // One write per page: the Usage pane's live observation re-fetches once per page.
            updated += try store.setCostsIfUnpriced(costs)
            if rows.count < batch { break }
        }
        if updated > 0 { log.info("repriced \(updated, privacy: .public) calls") }
        return updated
    }
}
