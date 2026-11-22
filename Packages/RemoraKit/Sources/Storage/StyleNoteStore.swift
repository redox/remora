import Foundation
import GRDB

/// A stored style note. `llmCallID` is nil for a note the user wrote or edited.
public struct StyleNote: Sendable, Equatable {
    public var surface: String
    public var notes: String
    public var updatedAt: Date
    public var llmCallID: Int64?
}

public struct StyleNoteStore: Sendable {
    private let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    public func note(for surface: String) throws -> String? {
        try db.reader.read { d in
            try String.fetchOne(d, sql: "SELECT notes FROM style_notes WHERE surface = ?", arguments: [surface])
        }
    }

    /// Every surface's notes; `"*"` is the all-surfaces note.
    public func all() throws -> [(surface: String, notes: String)] {
        try db.reader.read { d in
            try Row.fetchAll(d, sql: "SELECT surface, notes FROM style_notes ORDER BY surface")
                .map { (surface: $0["surface"] as String, notes: $0["notes"] as String) }
        }
    }

    public func row(for surface: String) throws -> StyleNote? {
        try db.reader.read { try row(for: surface, in: $0) }
    }

    /// Inside an existing transaction (the re-check before a pipeline writes).
    public func row(for surface: String, in d: Database) throws -> StyleNote? {
        try Row.fetchOne(d, sql: "SELECT surface, notes, updated_at, llm_call_id FROM style_notes WHERE surface = ?",
                         arguments: [surface]).map {
            StyleNote(surface: $0["surface"], notes: $0["notes"], updatedAt: $0["updated_at"], llmCallID: $0["llm_call_id"])
        }
    }

    /// Ownership contract: `llmCallID` non-nil marks a note the model wrote; a user edit must pass
    /// `nil`, which makes the note the user's, and background memory then only appends to it.
    public func upsert(surface: String, notes: String, llmCallID: Int64?, at: Date) throws {
        try db.writer.write { d in try upsert(surface: surface, notes: notes, llmCallID: llmCallID, at: at, in: d) }
    }

    /// Inside an existing write (e.g. `DataGeneration.write`).
    public func upsert(surface: String, notes: String, llmCallID: Int64?, at: Date, in d: Database) throws {
        try d.execute(sql: """
            INSERT INTO style_notes (surface, notes, updated_at, llm_call_id) VALUES (?, ?, ?, ?)
            ON CONFLICT(surface) DO UPDATE SET notes = excluded.notes,
                updated_at = excluded.updated_at, llm_call_id = excluded.llm_call_id
            """, arguments: [surface, notes, at, llmCallID])
    }
}
