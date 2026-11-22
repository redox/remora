import Foundation
import GRDB

public enum InlineMode: String, Codable, Sendable { case selection, full, draft, question, edit }
public enum InlineOutcome: String, Codable, Sendable { case kept, edited, discarded }

/// A rewrite/edit result shown inline. Callers redact text before inserting.
public struct InlineOutput: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var createdAt: Date
    public var llmCallID: Int64?
    public var mode: InlineMode
    public var app: String
    public var bundleID: String?
    public var surface: String
    public var original: String
    public var instruction: String?
    public var result: String
    public var outcome: InlineOutcome?
    public var finalText: String?
    public var checkedAt: Date?

    public init(id: Int64? = nil, createdAt: Date, llmCallID: Int64? = nil, mode: InlineMode,
                app: String, bundleID: String? = nil, surface: String, original: String,
                instruction: String? = nil, result: String, outcome: InlineOutcome? = nil,
                finalText: String? = nil, checkedAt: Date? = nil) {
        self.id = id; self.createdAt = createdAt; self.llmCallID = llmCallID; self.mode = mode
        self.app = app; self.bundleID = bundleID; self.surface = surface; self.original = original
        self.instruction = instruction; self.result = result; self.outcome = outcome
        self.finalText = finalText; self.checkedAt = checkedAt
    }

    public static let databaseTableName = "inline_outputs"

    enum CodingKeys: String, CodingKey {
        case id, mode, app, surface, original, instruction, result, outcome
        case createdAt = "created_at"
        case llmCallID = "llm_call_id"
        case bundleID = "bundle_id"
        case finalText = "final_text"
        case checkedAt = "checked_at"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct InlineOutputStore: Sendable {
    private let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    public func insert(_ o: InlineOutput) throws -> InlineOutput {
        try db.writer.write { d in
            var copy = o
            try copy.insert(d)
            return copy
        }
    }

    public func recordOutcome(id: Int64, outcome: InlineOutcome?, finalText: String?, at: Date) throws {
        try db.writer.write { d in
            try d.execute(sql: "UPDATE inline_outputs SET outcome = ?, final_text = ?, checked_at = ? WHERE id = ?",
                          arguments: [outcome?.rawValue, finalText, at, id])
        }
    }

    /// Newest first.
    public func recent(limit: Int) throws -> [InlineOutput] {
        try db.reader.read { d in
            try InlineOutput.fetchAll(d, sql: "SELECT * FROM inline_outputs ORDER BY created_at DESC, id DESC LIMIT ?",
                                      arguments: [limit])
        }
    }

    /// Outputs created after `date` (all when nil), oldest first, at most `limit`: the caller
    /// advances its watermark to the newest one it got, so a long backlog is read in order.
    public func since(_ date: Date?, limit: Int) throws -> [InlineOutput] {
        try db.reader.read { d in
            if let date {
                return try InlineOutput.fetchAll(d, sql: """
                    SELECT * FROM inline_outputs WHERE created_at > ? ORDER BY created_at, id LIMIT ?
                    """, arguments: [date, limit])
            }
            return try InlineOutput.fetchAll(d, sql: "SELECT * FROM inline_outputs ORDER BY created_at, id LIMIT ?",
                                             arguments: [limit])
        }
    }
}
