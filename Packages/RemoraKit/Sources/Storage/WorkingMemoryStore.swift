import Foundation
import GRDB

/// What the user is dealing with right now (`working_memory`): a small, decaying set of items.
///
/// Relevance decays with a 6-hour half-life from `last_seen_at`; an item is deleted once its
/// decayed relevance falls below 0.05 or it has not been seen for 24 hours, and at most 30 items
/// are kept (plan 4 pinned values). Items are keyed by `TextFold.key(text)` (F-66), so two
/// wordings that differ only in case, accents, quotes or punctuation are one item.
public struct WorkingMemoryStore: Sendable {
    public static let halfLife: TimeInterval = 21_600
    public static let minRelevance = 0.05
    public static let maxAge: TimeInterval = 86_400
    public static let maxItems = 30

    private let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    /// `relevance · 0.5^(Δ / halfLife)`, Δ = time since `last_seen_at` (never negative).
    public static func decayed(_ i: WorkingMemoryItem, now: Date) -> Double {
        let age = max(0, now.timeIntervalSince(i.lastSeenAt))
        return i.relevance * pow(0.5, age / halfLife)
    }

    /// Relevance clamped to 0…1 (a non-finite value is 0).
    static func clamped(_ r: Double) -> Double { r.isFinite ? min(max(r, 0), 1) : 0 }

    /// Merges `new` by norm key (`TextFold.key(text)`; an item without words is dropped): an item
    /// already stored keeps its id and `added_at`, takes the new text, kind and call, unions its
    /// snapshot ids, and gets `max(decayed stored relevance, new relevance)` re-anchored at
    /// `last_seen_at = now`. Then prunes (decayed < 0.05 or unseen > 24 h) and keeps the 30 most
    /// relevant (decayed). Inside the caller's write (`DataGeneration.write`).
    public func merge(_ new: [WorkingMemoryItem], now: Date, in d: Database) throws {
        var incoming: [String: WorkingMemoryItem] = [:]
        var order: [String] = []
        for var item in new {
            let key = TextFold.key(item.text)
            guard !key.isEmpty else { continue }
            item.normKey = key
            item.relevance = Self.clamped(item.relevance)
            if var seen = incoming[key] {
                seen.relevance = max(seen.relevance, item.relevance)
                seen.snapshotIDs = Self.union(seen.snapshotIDs, item.snapshotIDs)
                incoming[key] = seen
            } else {
                incoming[key] = item
                order.append(key)
            }
        }
        for key in order {
            guard var item = incoming[key] else { continue }
            if let stored = try WorkingMemoryItem.fetchOne(d, sql: "SELECT * FROM working_memory WHERE norm_key = ?",
                                                           arguments: [key]) {
                item.id = stored.id
                item.addedAt = stored.addedAt
                item.relevance = max(Self.decayed(stored, now: now), item.relevance)
                item.snapshotIDs = Self.union(stored.snapshotIDs, item.snapshotIDs)
                item.lastSeenAt = now
                try item.update(d)
            } else {
                item.id = nil
                item.lastSeenAt = now
                try item.insert(d)
            }
        }
        try prune(now: now, in: d)
    }

    /// Deletes faded, stale and surplus items.
    public func prune(now: Date, in d: Database) throws {
        let all = try WorkingMemoryItem.fetchAll(d, sql: "SELECT * FROM working_memory")
        let alive = all.filter {
            now.timeIntervalSince($0.lastSeenAt) <= Self.maxAge && Self.decayed($0, now: now) >= Self.minRelevance
        }
        let kept = Set(Self.ranked(alive, now: now).prefix(Self.maxItems).compactMap(\.id))
        let doomed = all.compactMap(\.id).filter { !kept.contains($0) }
        guard !doomed.isEmpty else { return }
        _ = try WorkingMemoryItem.deleteAll(d, keys: doomed)
    }

    /// The `n` most relevant items now (decayed relevance; ties: most recently seen first).
    public func top(_ n: Int, now: Date) throws -> [WorkingMemoryItem] {
        try db.reader.read { d in try top(n, now: now, in: d) }
    }

    public func top(_ n: Int, now: Date, in d: Database) throws -> [WorkingMemoryItem] {
        guard n > 0 else { return [] }
        return Array(Self.ranked(try WorkingMemoryItem.fetchAll(d, sql: "SELECT * FROM working_memory"), now: now)
            .prefix(n))
    }

    private static func ranked(_ items: [WorkingMemoryItem], now: Date) -> [WorkingMemoryItem] {
        items.map { ($0, decayed($0, now: now)) }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                if a.0.lastSeenAt != b.0.lastSeenAt { return a.0.lastSeenAt > b.0.lastSeenAt }
                return (a.0.id ?? 0) < (b.0.id ?? 0)
            }
            .map(\.0)
    }

    /// Sorted, without duplicates.
    private static func union(_ a: [Int64], _ b: [Int64]) -> [Int64] { Array(Set(a).union(b)).sorted() }
}
