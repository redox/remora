import Foundation
import GRDB

/// The identity profile: an append-only history of revisions (`llm` or `user`); the newest is
/// current. User edits are revisions too, so the pipeline can tell which lines the user wrote or
/// removed. Callers redact LLM text before inserting. Never log revision text.
public struct IdentityStore: IdentityReading, Sendable {
    private let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    public func current() throws -> IdentityRevision? {
        try db.reader.read { try Self.current(in: $0) }
    }

    public static func current(in d: Database) throws -> IdentityRevision? {
        try IdentityRevision.fetchOne(d, sql: "SELECT * FROM identity ORDER BY id DESC LIMIT 1")
    }

    /// Newest first.
    public func history(limit: Int) throws -> [IdentityRevision] {
        try db.reader.read { d in
            try IdentityRevision.fetchAll(d, sql: "SELECT * FROM identity ORDER BY id DESC LIMIT ?", arguments: [limit])
        }
    }

    /// Every revision, oldest first (the order the user-edit constraints are replayed in).
    public static func all(in d: Database) throws -> [IdentityRevision] {
        try IdentityRevision.fetchAll(d, sql: "SELECT * FROM identity ORDER BY id")
    }

    /// Stores the user's text as a `user` revision. Returns the current revision unchanged when
    /// the text (trimmed) equals it.
    @discardableResult
    public func saveUserEdit(_ body: String, at: Date) throws -> IdentityRevision {
        try db.writer.write { d in try Self.saveUserEdit(body, at: at, in: d) }
    }

    /// `saveUserEdit(_:at:)` inside an existing write (e.g. `DataGeneration.write`).
    @discardableResult
    public static func saveUserEdit(_ body: String, at: Date, in d: Database) throws -> IdentityRevision {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if let current = try current(in: d),
           current.body.trimmingCharacters(in: .whitespacesAndNewlines) == text { return current }
        var row = IdentityRevision(body: text, source: .user, createdAt: at)
        try row.insert(d)
        return row
    }

    /// An LLM revision, inside an existing write (e.g. `DataGeneration.write`).
    @discardableResult
    public func insertLLM(_ body: String, llmCallID: Int64?, at: Date, in d: Database) throws -> IdentityRevision {
        var row = IdentityRevision(body: body, source: .llm, createdAt: at, llmCallID: llmCallID)
        try row.insert(d)
        return row
    }

    public func lastLLMRevision() throws -> IdentityRevision? {
        try db.reader.read { d in
            try IdentityRevision.fetchOne(d, sql: "SELECT * FROM identity WHERE source = 'llm' ORDER BY id DESC LIMIT 1")
        }
    }

    /// The newest `user` revision newer than the last `llm` one (any user revision when there is
    /// no LLM one); nil when the newest revision is the LLM's or there is none.
    public func latestUserRevisionAfterLastLLM() throws -> IdentityRevision? {
        try db.reader.read { d in
            try IdentityRevision.fetchOne(d, sql: """
                SELECT * FROM identity WHERE source = 'user'
                AND id > COALESCE((SELECT MAX(id) FROM identity WHERE source = 'llm'), 0)
                ORDER BY id DESC LIMIT 1
                """)
        }
    }
}
