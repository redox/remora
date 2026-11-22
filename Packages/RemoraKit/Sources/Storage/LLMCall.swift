import Foundation
import GRDB

public enum LLMCallStatus: String, Codable, Sendable { case completed, failed, limit, cancelled }

/// One model call (accounting only; holds no prompt or output content).
public struct LLMCall: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var startedAt: Date
    public var durationMs: Int
    public var backend: String
    public var model: String
    public var reasoningEffort: String?
    public var jobType: String
    public var status: LLMCallStatus
    public var errorCode: String?
    public var inputTokens: Int
    public var cachedInputTokens: Int
    public var outputTokens: Int
    public var reasoningTokens: Int
    public var estCostUSD: Double?
    public var artifactTable: String?
    public var artifactID: Int64?

    public init(id: Int64? = nil, startedAt: Date, durationMs: Int, backend: String, model: String,
                reasoningEffort: String? = nil, jobType: String, status: LLMCallStatus,
                errorCode: String? = nil, inputTokens: Int = 0, cachedInputTokens: Int = 0,
                outputTokens: Int = 0, reasoningTokens: Int = 0, estCostUSD: Double? = nil,
                artifactTable: String? = nil, artifactID: Int64? = nil) {
        self.id = id; self.startedAt = startedAt; self.durationMs = durationMs
        self.backend = backend; self.model = model; self.reasoningEffort = reasoningEffort
        self.jobType = jobType; self.status = status; self.errorCode = errorCode
        self.inputTokens = inputTokens; self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens; self.reasoningTokens = reasoningTokens
        self.estCostUSD = estCostUSD; self.artifactTable = artifactTable; self.artifactID = artifactID
    }

    public static let databaseTableName = "llm_calls"

    enum CodingKeys: String, CodingKey {
        case id, backend, model, status
        case startedAt = "started_at"
        case durationMs = "duration_ms"
        case reasoningEffort = "reasoning_effort"
        case jobType = "job_type"
        case errorCode = "error_code"
        case inputTokens = "input_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case outputTokens = "output_tokens"
        case reasoningTokens = "reasoning_tokens"
        case estCostUSD = "est_cost_usd"
        case artifactTable = "artifact_table"
        case artifactID = "artifact_id"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public enum UsageGrouping: Sendable { case day(Calendar), jobType, model }

public struct UsageTotals: Sendable, Equatable, Codable {
    public var key: String
    public var calls: Int
    public var inputTokens: Int
    public var cachedInputTokens: Int
    public var outputTokens: Int
    public var reasoningTokens: Int
    /// Sum over priced rows; nil when every row is unpriced.
    public var estCostUSD: Double?
    public var unpricedCalls: Int

    public init(key: String, calls: Int = 0, inputTokens: Int = 0, cachedInputTokens: Int = 0,
                outputTokens: Int = 0, reasoningTokens: Int = 0, estCostUSD: Double? = nil,
                unpricedCalls: Int = 0) {
        self.key = key; self.calls = calls; self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens; self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens; self.estCostUSD = estCostUSD
        self.unpricedCalls = unpricedCalls
    }
}

public struct LLMCallStore: Sendable {
    private let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    public func insert(_ c: LLMCall) throws -> LLMCall {
        try db.writer.write { d in
            var copy = c
            try copy.insert(d)
            return copy
        }
    }

    public func setArtifact(callID: Int64, table: String, id: Int64) throws {
        try db.writer.write { d in try setArtifact(callID: callID, table: table, id: id, in: d) }
    }

    /// Inside an existing write (e.g. `DataGeneration.write`). `id` is nil when a call produced
    /// several rows of `table`.
    public func setArtifact(callID: Int64, table: String, id: Int64?, in d: Database) throws {
        try d.execute(sql: "UPDATE llm_calls SET artifact_table = ?, artifact_id = ? WHERE id = ?",
                      arguments: [table, id, callID])
    }

    public func generatedBy(callID: Int64) throws -> GeneratedBy? {
        try db.reader.read { d in try Self.generatedBy(callID: callID, in: d) }
    }

    /// nil when the call row is gone.
    public static func generatedBy(callID: Int64, in d: Database) throws -> GeneratedBy? {
        try LLMCall.fetchOne(d, key: callID).map {
            GeneratedBy(model: $0.model, backend: $0.backend, inputTokens: $0.inputTokens,
                        outputTokens: $0.outputTokens, estCostUSD: $0.estCostUSD, at: $0.startedAt)
        }
    }

    /// Newest first.
    public func recent(limit: Int) throws -> [LLMCall] {
        try db.reader.read { d in
            try LLMCall.fetchAll(d, sql: "SELECT * FROM llm_calls ORDER BY started_at DESC, id DESC LIMIT ?",
                                 arguments: [limit])
        }
    }

    /// Rows with `since <= started_at < until` (no upper bound when nil), aggregated in Swift.
    /// `.day` sorts by key ascending; the others by total tokens descending (ties by key).
    public func totals(_ g: UsageGrouping, since: Date, until: Date? = nil) throws -> [UsageTotals] {
        let rows = try db.reader.read { d in
            try LLMCall.fetchAll(d, sql: """
                SELECT * FROM llm_calls WHERE started_at >= ? AND (? IS NULL OR started_at < ?)
                """, arguments: [since, until, until])
        }
        var byKey: [String: UsageTotals] = [:]
        for r in rows {
            let key: String
            switch g {
            case .day(let cal):
                let c = cal.dateComponents([.year, .month, .day], from: r.startedAt)
                key = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
            case .jobType: key = r.jobType
            case .model: key = r.model
            }
            var t = byKey[key] ?? UsageTotals(key: key)
            t.calls += 1
            t.inputTokens += r.inputTokens
            t.cachedInputTokens += r.cachedInputTokens
            t.outputTokens += r.outputTokens
            t.reasoningTokens += r.reasoningTokens
            if let cost = r.estCostUSD { t.estCostUSD = (t.estCostUSD ?? 0) + cost } else { t.unpricedCalls += 1 }
            byKey[key] = t
        }
        let all = Array(byKey.values)
        if case .day = g { return all.sorted { $0.key < $1.key } }
        return all.sorted {
            let a = $0.inputTokens + $0.outputTokens, b = $1.inputTokens + $1.outputTokens
            return a != b ? a > b : $0.key < $1.key
        }
    }
}
