import Foundation
import GRDB

/// A counter that "Delete all data" bumps. A background job reads it before its (slow) model
/// call and writes its result through `write(expected:)`, which refuses the write when a
/// delete-all happened in between, so nothing derived from deleted data reappears.
///
/// Stored as the JSON setting `memory.dataGeneration` (absent = 0), read and bumped with raw
/// SQL on the given connection: GRDB writes are not reentrant, so no store call may open its
/// own write inside `write`.
public enum DataGeneration {
    public struct Stale: Error, Equatable { public init() {} }

    static let key = "memory.dataGeneration"

    public static func current(_ db: AppDatabase) throws -> Int {
        try db.reader.read { try current(in: $0) }
    }

    /// Runs `body` in one write transaction, after checking (inside that transaction) that the
    /// generation still equals `expected`; throws `Stale` without running `body` otherwise.
    /// A corrupt stored value throws `SettingsStore.CorruptValue` (fail closed).
    public static func write<T>(_ db: AppDatabase, expected: Int, _ body: (Database) throws -> T) throws -> T {
        try db.writer.write { d in
            guard try current(in: d) == expected else { throw Stale() }
            return try body(d)
        }
    }

    static func current(in d: Database) throws -> Int {
        try SettingsStore.jsonValue(Int.self, forKey: key, in: d) ?? 0
    }

    /// Increments the generation. A corrupt (previous = 0) or overflowing value is repaired to
    /// `max(previous, epoch-ms) &+ 1`: above any value a job could have read before, so no stale
    /// write passes after a repair, and `Int.max` wraps instead of trapping. Delete-all never
    /// fails on it.
    static func bump(in d: Database, now: Date = Date()) throws {
        let next: Int
        do {
            let previous = try current(in: d)
            let (sum, overflow) = previous.addingReportingOverflow(1)
            next = overflow ? repaired(previous: previous, now: now) : sum
        } catch is SettingsStore.CorruptValue {
            next = repaired(previous: 0, now: now)
        }
        try SettingsStore.store(try SettingsStore.json(next), forKey: key, in: d)
    }

    private static func repaired(previous: Int, now: Date) -> Int {
        let ms = (now.timeIntervalSince1970 * 1000).rounded(.down)
        let epochMs = ms.isFinite && ms >= 0 && ms < Double(Int.max) ? Int(ms) : 0
        return max(previous, epochMs) &+ 1
    }
}
