import Foundation
import GRDB

public struct ExclusionStore: Sendable {
    /// Thrown for patterns that are empty or are a bare `app:`/`title:`/`url:`/`path:` prefix.
    public struct InvalidPattern: Error, Equatable { public let pattern: String }

    public struct Entry: FetchableRecord, Decodable, Sendable {
        public let pattern: String
        public let manualSaves: Bool
        private enum CodingKeys: String, CodingKey {
            case pattern
            case manualSaves = "manual_saves"
        }
    }

    private static let prefixes = ["app:", "title:", "url:", "path:"]
    private let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    public func all() throws -> [String] {
        try db.reader.read { try Self.all(in: $0) }
    }

    public static func all(in d: Database) throws -> [String] {
        try String.fetchAll(d, sql: "SELECT pattern FROM exclusions ORDER BY id")
    }

    public func entries() throws -> [Entry] { try db.reader.read { try Self.entries(in: $0) } }

    public static func entries(in d: Database) throws -> [Entry] {
        try Entry.fetchAll(d, sql: "SELECT pattern, manual_saves FROM exclusions ORDER BY id")
    }

    /// Changes the selection-save permission without changing the background exclusion.
    public func setManualSaves(_ enabled: Bool, for pattern: String) throws {
        try db.writer.write { d in
            try d.execute(sql: "UPDATE exclusions SET manual_saves = ? WHERE pattern = ?",
                          arguments: [enabled, pattern])
        }
    }

    /// Idempotent. Storage cannot see `Capture.ExclusionRule`, so it only checks basic well-formedness.
    public func add(_ pattern: String) throws {
        try db.writer.write { d in _ = try Self.add(pattern, at: Date(), in: d) }
    }

    public func remove(_ pattern: String) throws {
        try db.writer.write { d in _ = try Self.remove(pattern, in: d) }
    }

    /// `add(_:)` inside an existing write (e.g. `DataGeneration.write`). Returns false when the
    /// pattern was already there (nothing changed).
    @discardableResult
    public static func add(_ pattern: String, at: Date, in d: Database) throws -> Bool {
        let p = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = p.lowercased()
        let bareEmpty = prefixes.contains { lower.hasPrefix($0)
            && p.dropFirst($0.count).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !p.isEmpty, !bareEmpty else { throw InvalidPattern(pattern: pattern) }
        try d.execute(sql: "INSERT OR IGNORE INTO exclusions (pattern, created_at) VALUES (?, ?)", arguments: [p, at])
        guard d.changesCount > 0 else { return false }
        try RoutineFindings.clearMessages(in: d)
        return true
    }

    /// `remove(_:)` inside an existing write. Returns false when there was no such pattern.
    @discardableResult
    public static func remove(_ pattern: String, in d: Database) throws -> Bool {
        let p = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        try d.execute(sql: "DELETE FROM exclusions WHERE pattern = ?", arguments: [p])
        return d.changesCount > 0
    }
}
extension ExclusionStore {
    /// Seeded once as ordinary, user-removable exclusions (not built in). AI chat apps and
    /// sites would re-capture Remora's own MCP answers (a feedback loop) and dominate storage;
    /// terminals run Claude Code (same loop) and show environment secrets.
    public static let defaultPatterns: [String] = [
        "app:Claude", "app:ChatGPT", "app:Cursor", "claude.ai", "chatgpt.com", "chat.openai.com",
        "app:Alacritty", "app:Ghostty", "app:iTerm2", "app:Terminal",
    ]

    static let defaultsSeededKey = "defaultExclusionsSeeded"

    /// Inserts `defaultPatterns` (INSERT OR IGNORE: existing rows, including ones the user
    /// added by hand, are untouched and never duplicated) and sets the
    /// `defaultExclusionsSeeded` flag, in one transaction. Once the flag is set this is a
    /// no-op, so a default the user removed never comes back. Returns true if it seeded.
    @discardableResult
    public func seedDefaults(now: Date = Date()) throws -> Bool {
        try db.writer.write { d in
            let seeded = try Bool.fetchOne(d, sql: "SELECT 1 FROM settings WHERE key = ?",
                                           arguments: [Self.defaultsSeededKey]) ?? false
            if seeded { return false }
            for pattern in Self.defaultPatterns {
                try d.execute(sql: "INSERT OR IGNORE INTO exclusions (pattern, created_at) VALUES (?, ?)",
                              arguments: [pattern, now])
            }
            try d.execute(sql: "INSERT OR REPLACE INTO settings (key, value) VALUES (?, '1')",
                          arguments: [Self.defaultsSeededKey])
            return true
        }
    }
}
