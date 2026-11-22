import Foundation
import Synchronization
import os

public struct ModelPrice: Codable, Sendable, Equatable {
    public var inputPer1M: Double?
    public var cachedInputPer1M: Double?
    public var outputPer1M: Double?
    /// Higher prices for the whole request once its input exceeds a context size.
    public var longContext: LongContextPrice?
    public init(inputPer1M: Double? = nil, cachedInputPer1M: Double? = nil, outputPer1M: Double? = nil,
                longContext: LongContextPrice? = nil) {
        self.inputPer1M = inputPer1M; self.cachedInputPer1M = cachedInputPer1M; self.outputPer1M = outputPer1M
        self.longContext = longContext
    }
    enum CodingKeys: String, CodingKey {
        case inputPer1M = "input_per_1m", cachedInputPer1M = "cached_input_per_1m", outputPer1M = "output_per_1m"
        case longContext = "long_context"
    }

    /// Field by field, `override`'s non-null values win.
    func overlaid(by override: ModelPrice) -> ModelPrice {
        ModelPrice(inputPer1M: override.inputPer1M ?? inputPer1M,
                   cachedInputPer1M: override.cachedInputPer1M ?? cachedInputPer1M,
                   outputPer1M: override.outputPer1M ?? outputPer1M,
                   longContext: override.longContext ?? longContext)
    }
}

public struct LongContextPrice: Codable, Sendable, Equatable {
    public var aboveInputTokens: Int
    public var inputPer1M: Double
    public var cachedInputPer1M: Double?
    public var outputPer1M: Double
    public init(aboveInputTokens: Int, inputPer1M: Double, cachedInputPer1M: Double? = nil, outputPer1M: Double) {
        self.aboveInputTokens = aboveInputTokens; self.inputPer1M = inputPer1M
        self.cachedInputPer1M = cachedInputPer1M; self.outputPer1M = outputPer1M
    }
    enum CodingKeys: String, CodingKey {
        case aboveInputTokens = "above_input_tokens", inputPer1M = "input_per_1m"
        case cachedInputPer1M = "cached_input_per_1m", outputPer1M = "output_per_1m"
    }
}

/// API-equivalent USD per 1M tokens. Ships with `builtIn` (models.dev); the user's
/// `model-prices.json` overrides it field by field. No entry means no cost.
public struct PriceTable: Codable, Sendable, Equatable {
    public var models: [String: ModelPrice]
    public init(models: [String: ModelPrice] = [:]) { self.models = models }
    public static let empty = PriceTable()

    /// OpenAI API list prices from https://models.dev/api.json, fetched 2026-11-20. Above 272k input
    /// tokens the whole request is billed at the long-context rate. Cache writes are not billed by
    /// the Responses API, so they are not listed.
    public static let builtIn: PriceTable = {
        func p(_ i: Double, _ c: Double, _ o: Double, long li: Double, _ lc: Double, _ lo: Double) -> ModelPrice {
            ModelPrice(inputPer1M: i, cachedInputPer1M: c, outputPer1M: o,
                       longContext: LongContextPrice(aboveInputTokens: 272_000, inputPer1M: li, cachedInputPer1M: lc, outputPer1M: lo))
        }
        return PriceTable(models: [
            "gpt-6-luna":    p(0.1, 0.01, 0.5,  long: 0.2, 0.02, 0.75),
            "gpt-6.1-terra": p(1,   0.05, 5,    long: 2,   0.1,  7.5),
            "gpt-6-sol":     p(2,   0.2,  10,   long: 4,   0.4,  15),
            "gpt-6.1-sol":   p(2,   0.1,  10,   long: 4,   0.2,  15),
            "gpt-6.2-sol":   p(2,   0.1,  10,   long: 4,   0.2,  15),
            "gpt-6-astra":   p(10,  1,    50,   long: 20,  2,    75),
            "gpt-6.2-astra": p(8,   0.4,  40,   long: 16,  0.8,  60),
            "gpt-5.6-luna":  p(0.2, 0.02, 1.2,  long: 0.4, 0.04, 1.8),
            "gpt-5.6-terra": p(2,   0.2,  12,   long: 4,   0.4,  18),
            "gpt-5.6-sol":   p(4,   0.4,  20,   long: 8,   0.8,  30),
            "gpt-5.6":       p(4,   0.4,  20,   long: 8,   0.8,  30),
        ])
    }()

    /// This table with `override` on top: per model, field by field (a null keeps this table's value).
    public func overlaid(by override: PriceTable) -> PriceTable {
        var merged = models
        for (slug, price) in override.models {
            merged[slug] = merged[slug].map { $0.overlaid(by: price) } ?? price
        }
        return PriceTable(models: merged)
    }

    /// `~/Library/Application Support/Remora/model-prices.json`
    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "Remora/model-prices.json", directoryHint: .notDirectory)
    }

    /// Missing or invalid file → `.empty`.
    public static func load(from url: URL) -> PriceTable { decode(from: url) ?? .empty }

    /// nil when the file is missing or does not decode.
    static func decode(from url: URL) -> PriceTable? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PriceTable.self, from: data)
    }

    /// A file to edit: the built-in prices for known slugs, null for the others.
    public static func template(slugs: [String]) -> Data {
        struct Template: Encodable {
            let _comment: String
            let models: [String: ModelPrice]
        }
        let t = Template(
            _comment: "API-equivalent USD per 1M tokens. Built-in prices come from models.dev (2026-11-20); values here override them, null keeps the built-in price. A model with no price has no cost estimate.",
            models: Dictionary(slugs.map { ($0, builtIn.models[$0] ?? ModelPrice()) }, uniquingKeysWith: { a, _ in a }))
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Optionals are omitted by the synthesized encoder; write explicit nulls.
        let raw = (try? enc.encode(t)) ?? Data()
        guard var obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              var models = obj["models"] as? [String: [String: Any]] else { return raw }
        for slug in models.keys {
            for key in ["input_per_1m", "cached_input_per_1m", "output_per_1m"] where models[slug]?[key] == nil {
                models[slug]?[key] = NSNull()
            }
        }
        obj["models"] = models
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])) ?? raw
    }

    /// On-device is free (0). Otherwise nil without an entry or without input and output prices;
    /// reasoning tokens are already part of the output count. Input above the long-context size
    /// bills the whole request at the long-context prices.
    public func cost(model: String, usage: LLMUsage, backend: LLMBackend) -> Double? {
        if backend == .onDevice { return 0 }
        guard let base = models[model] else { return nil }
        var p = base
        if let long = base.longContext, usage.inputTokens > long.aboveInputTokens {
            p = ModelPrice(inputPer1M: long.inputPer1M, cachedInputPer1M: long.cachedInputPer1M, outputPer1M: long.outputPer1M)
        }
        guard let input = p.inputPer1M, let output = p.outputPer1M,
              input >= 0, output >= 0, (p.cachedInputPer1M ?? 0) >= 0 else { return nil }
        let cached = Double(max(0, min(usage.cachedInputTokens, usage.inputTokens)))
        let fresh = Double(usage.inputTokens) - cached
        return (fresh * input + cached * (p.cachedInputPer1M ?? input) + Double(usage.outputTokens) * output) / 1e6
    }
}

/// `defaults` overlaid by the price file, reloading when the file's modification date changes. When an
/// existing file fails to decode, the last good table is kept (logged once per file version, no content).
public final class PriceTableFile: Sendable {
    private struct State { var mtime: Date?; var table = PriceTable.empty; var loaded = false }
    private let url: URL
    private let defaults: PriceTable
    private let state = Mutex(State())
    private static let log = Logger(subsystem: "dev.remora", category: "llm")

    public init(url: URL = PriceTable.defaultURL, defaults: PriceTable = .builtIn) {
        self.url = url; self.defaults = defaults
    }

    public func table() -> PriceTable {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        return state.withLock { s in
            if !s.loaded || s.mtime != mtime {
                if mtime == nil {
                    s.table = defaults
                } else if let t = PriceTable.decode(from: url) {
                    s.table = defaults.overlaid(by: t)
                } else if !s.loaded {
                    s.table = defaults
                    Self.log.error("model-prices.json did not decode; using the built-in prices")
                } else {
                    Self.log.error("model-prices.json did not decode; keeping the last good table")
                }
                s.mtime = mtime
                s.loaded = true
            }
            return s.table
        }
    }
}
