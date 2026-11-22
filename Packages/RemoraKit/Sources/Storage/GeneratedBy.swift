import Foundation

/// Provenance of generated content (spec JSON shape): `{model, backend, input_tokens,
/// output_tokens, est_cost_usd, at}`; `at` is unix seconds, `est_cost_usd` is `null` when unpriced.
public struct GeneratedBy: Codable, Sendable, Equatable {
    public var model: String
    public var backend: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var estCostUSD: Double?
    public var at: Date

    public init(model: String, backend: String, inputTokens: Int, outputTokens: Int,
                estCostUSD: Double?, at: Date) {
        self.model = model; self.backend = backend; self.inputTokens = inputTokens
        self.outputTokens = outputTokens; self.estCostUSD = estCostUSD; self.at = at
    }

    enum CodingKeys: String, CodingKey {
        case model, backend, at
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case estCostUSD = "est_cost_usd"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decode(String.self, forKey: .model)
        backend = try c.decode(String.self, forKey: .backend)
        inputTokens = try c.decode(Int.self, forKey: .inputTokens)
        outputTokens = try c.decode(Int.self, forKey: .outputTokens)
        estCostUSD = try c.decodeIfPresent(Double.self, forKey: .estCostUSD)
        at = Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .at))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(model, forKey: .model)
        try c.encode(backend, forKey: .backend)
        try c.encode(inputTokens, forKey: .inputTokens)
        try c.encode(outputTokens, forKey: .outputTokens)
        if let estCostUSD { try c.encode(estCostUSD, forKey: .estCostUSD) } else { try c.encodeNil(forKey: .estCostUSD) }
        try c.encode(at.timeIntervalSince1970, forKey: .at)
    }
}
