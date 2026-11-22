import Foundation
import GRDB

public struct SettingsStore: Sendable {
    /// Thrown when a stored setting exists but cannot be parsed.
    public struct CorruptValue: Error, Equatable { public let key: String }

    private static let pausedUntilKey = "pausedUntil"
    private let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    /// Epoch seconds stored as text. `.distantFuture` means paused indefinitely.
    public func pausedUntil() throws -> Date? {
        let raw = try db.reader.read { d in
            try String.fetchOne(d, sql: "SELECT value FROM settings WHERE key = ?",
                                arguments: [Self.pausedUntilKey])
        }
        guard let raw else { return nil }
        guard let seconds = Double(raw), seconds.isFinite else { throw CorruptValue(key: Self.pausedUntilKey) }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Pause check inside an existing transaction. A corrupt value counts as paused.
    static func isPausedFailClosed(_ d: Database, now: Date) throws -> Bool {
        let raw = try String.fetchOne(d, sql: "SELECT value FROM settings WHERE key = ?",
                                      arguments: [pausedUntilKey])
        guard let raw else { return false }
        guard let seconds = Double(raw), seconds.isFinite else { return true }
        return Date(timeIntervalSince1970: seconds) > now
    }

    /// `pausedUntil()` on an existing connection (e.g. inside `DataGeneration.write`).
    public func pausedUntil(in d: Database) throws -> Date? {
        guard let raw = try String.fetchOne(d, sql: "SELECT value FROM settings WHERE key = ?",
                                            arguments: [Self.pausedUntilKey]) else { return nil }
        guard let seconds = Double(raw), seconds.isFinite else { throw CorruptValue(key: Self.pausedUntilKey) }
        return Date(timeIntervalSince1970: seconds)
    }

    /// `nil` resumes capture.
    public func pause(until: Date?) throws {
        try db.writer.write { d in try pause(until: until, in: d) }
    }

    /// `pause(until:)` inside an existing write.
    public func pause(until: Date?, in d: Database) throws {
        if let until {
            try d.execute(
                sql: "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)",
                arguments: [Self.pausedUntilKey, String(until.timeIntervalSince1970)])
        } else {
            try d.execute(sql: "DELETE FROM settings WHERE key = ?",
                          arguments: [Self.pausedUntilKey])
        }
    }

    public func isPaused(now: Date) throws -> Bool {
        guard let until = try pausedUntil() else { return false }
        return until > now
    }

    private static let windowBadgeKey = "windowBadgeEnabled"

    /// Optional per-window badge. Missing = off; anything but "1"/"0" throws.
    public func windowBadgeEnabled() throws -> Bool {
        try db.reader.read { d in try windowBadgeEnabled(in: d) }
    }

    /// `windowBadgeEnabled()` on an existing connection.
    public func windowBadgeEnabled(in d: Database) throws -> Bool {
        let raw = try String.fetchOne(d, sql: "SELECT value FROM settings WHERE key = ?",
                                      arguments: [Self.windowBadgeKey])
        switch raw {
        case nil, "0": return false
        case "1": return true
        default: throw CorruptValue(key: Self.windowBadgeKey)
        }
    }

    public func setWindowBadgeEnabled(_ on: Bool) throws {
        try db.writer.write { d in try setWindowBadgeEnabled(on, in: d) }
    }

    /// `setWindowBadgeEnabled(_:)` inside an existing write.
    public func setWindowBadgeEnabled(_ on: Bool, in d: Database) throws {
        try d.execute(sql: "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)",
                      arguments: [Self.windowBadgeKey, on ? "1" : "0"])
    }

    // MARK: JSON values

    /// A JSON-encoded setting; nil when the key is absent. Undecodable JSON throws `CorruptValue`.
    public func value<T: Decodable>(_ type: T.Type, forKey key: String) throws -> T? {
        try db.reader.read { d in try value(type, forKey: key, in: d) }
    }

    /// Stores JSON text; nil deletes the key.
    public func setValue<T: Encodable>(_ value: T?, forKey key: String) throws {
        let json = try Self.json(value)
        try db.writer.write { d in try Self.store(json, forKey: key, in: d) }
    }

    /// `value(_:forKey:)` on an existing connection (e.g. inside `DataGeneration.write`).
    public func value<T: Decodable>(_ type: T.Type, forKey key: String, in d: Database) throws -> T? {
        try Self.jsonValue(type, forKey: key, in: d)
    }

    /// `setValue(_:forKey:)` inside an existing write (e.g. `DataGeneration.write`).
    public func setValue<T: Encodable>(_ value: T?, forKey key: String, in d: Database) throws {
        try Self.store(try Self.json(value), forKey: key, in: d)
    }

    /// Raw-SQL read on the given connection (no store call, so safe inside any write).
    static func jsonValue<T: Decodable>(_ type: T.Type, forKey key: String, in d: Database) throws -> T? {
        guard let raw = try String.fetchOne(d, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key])
        else { return nil }
        guard let decoded = try? JSONDecoder().decode(T.self, from: Data(raw.utf8)) else {
            throw CorruptValue(key: key)
        }
        return decoded
    }

    static func json<T: Encodable>(_ value: T?) throws -> String? {
        try value.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
    }

    /// Raw-SQL write on the given connection; nil deletes the key.
    static func store(_ json: String?, forKey key: String, in d: Database) throws {
        if let json {
            try d.execute(sql: "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)", arguments: [key, json])
        } else {
            try d.execute(sql: "DELETE FROM settings WHERE key = ?", arguments: [key])
        }
    }
}
