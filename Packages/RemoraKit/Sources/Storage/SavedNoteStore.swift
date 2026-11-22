import Foundation
import GRDB

public struct SavedNote: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    public static let databaseTableName = "saved_notes"
    public let id: UUID
    public let text: String
    public let annotation: String
    public let createdAt: Date

    public init(text: String, annotation: String, createdAt: Date) {
        id = UUID()
        self.text = text
        self.annotation = annotation
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, annotation
        case createdAt = "created_at"
    }
}

/// Explicitly saved text has its own index and lifetime. Capture jobs never read this table.
public struct SavedNoteStore: Sendable {
    static let chatKey = "savedNotes.chatAccess"
    private let db: AppDatabase

    public init(_ db: AppDatabase) { self.db = db }

    public static func insert(_ note: SavedNote, in d: Database) throws {
        try note.insert(d)
    }

    public func list(query: String = "", limit: Int = 100) throws -> [SavedNote] {
        try db.reader.read { try Self.list(query: query, limit: limit, in: $0) }
    }

    private static func list(query: String, limit: Int, in d: Database) throws -> [SavedNote] {
        let limit = min(max(limit, 1), 100)
        guard query.utf8.count <= 256 else { return [] }
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try SavedNote.fetchAll(d, sql: "SELECT * FROM saved_notes ORDER BY created_at DESC, rowid DESC LIMIT ?",
                                          arguments: [limit])
        }
        guard let match = FTSQuery.make(from: query) else { return [] }
        return try SavedNote.fetchAll(d, sql: """
            SELECT n.* FROM saved_notes_fts JOIN saved_notes n ON n.rowid = saved_notes_fts.rowid
            WHERE saved_notes_fts MATCH ? ORDER BY rank, n.created_at DESC, n.rowid DESC LIMIT ?
            """, arguments: [match, limit])
    }

    public func delete(_ id: UUID, now: Date = Date()) throws {
        try db.writer.write { d in
            if try SavedNote.deleteOne(d, key: id),
               (try? Self.chatAccessEnabled(in: d)) != false {
                try ForgetMarks.markChat(now: now, in: d)
            }
        }
    }

    public func chatAccessEnabled() throws -> Bool {
        try db.reader.read { try Self.chatAccessEnabled(in: $0) }
    }

    private static func chatAccessEnabled(in d: Database) throws -> Bool {
        try SettingsStore.jsonValue(Bool.self, forKey: chatKey, in: d) == true
    }

    public func canSearchInChat(now: Date) throws -> Bool {
        try db.reader.read { try Self.canSearchInChat(now: now, in: $0) }
    }

    private static func canSearchInChat(now: Date, in d: Database) throws -> Bool {
        try chatAccessEnabled(in: d) && !SettingsStore.isPausedFailClosed(d, now: now)
    }

    public func setChatAccess(_ enabled: Bool, now: Date = Date()) throws {
        try db.writer.write { d in
            try SettingsStore.store(try SettingsStore.json(enabled), forKey: Self.chatKey, in: d)
            if !enabled { try ForgetMarks.markChat(now: now, in: d) }
        }
    }

    /// Search and permissions share one read. The turn rechecks permission and the forget
    /// watermark before sending any results or replaying a note-backed reply.
    public func searchForChat(_ query: String, now: Date) async throws -> [SavedNote]? {
        try await db.reader.read { d in
            guard try Self.canSearchInChat(now: now, in: d) else { return nil }
            return try Self.list(query: query, limit: 5, in: d)
        }
    }

    public func canUseChatContext(since started: Date, now: Date) async throws -> Bool {
        try await db.reader.read { d in
            guard try Self.canSearchInChat(now: now, in: d) else { return false }
            return ForgetMarks.chatForgetAt(in: d).map { $0 <= started } ?? true
        }
    }
}
