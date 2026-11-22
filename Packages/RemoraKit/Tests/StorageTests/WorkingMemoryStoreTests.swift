import Foundation
import GRDB
import Testing
@testable import Storage

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let hour: TimeInterval = 3_600

private func item(_ text: String, _ relevance: Double, seen: Date = now, ids: [Int64] = [],
                  kind: String = "topic") -> WorkingMemoryItem {
    WorkingMemoryItem(text: text, kind: kind, normKey: TextFold.key(text), relevance: relevance, snapshotIDs: ids,
                      addedAt: seen, lastSeenAt: seen)
}

private func merge(_ db: AppDatabase, _ items: [WorkingMemoryItem], at: Date) throws {
    try db.writer.write { d in try WorkingMemoryStore(db).merge(items, now: at, in: d) }
}

private func rows(_ db: AppDatabase) throws -> [WorkingMemoryItem] {
    try db.reader.read { d in try WorkingMemoryItem.fetchAll(d, sql: "SELECT * FROM working_memory ORDER BY id") }
}

@Test func decayHalvesEverySixHours() {
    #expect(WorkingMemoryStore.halfLife == 21_600)
    let sixHoursAgo = item("Oslo budget", 0.8, seen: now.addingTimeInterval(-6 * hour))
    #expect(abs(WorkingMemoryStore.decayed(sixHoursAgo, now: now) - 0.4) < 1e-12)
    let twelveHoursAgo = item("Oslo budget", 0.8, seen: now.addingTimeInterval(-12 * hour))
    #expect(abs(WorkingMemoryStore.decayed(twelveHoursAgo, now: now) - 0.2) < 1e-12)
    #expect(WorkingMemoryStore.decayed(item("Oslo budget", 0.8), now: now) == 0.8)
    // A last_seen in the future (clock change) never inflates relevance.
    #expect(WorkingMemoryStore.decayed(item("x", 0.8, seen: now.addingTimeInterval(hour)), now: now) == 0.8)
}

@Test func mergeKeepsMaxRelevanceAndPrunes() throws {
    let db = try AppDatabase.inMemory()
    // Seen 25 h ago: removed by age. Seen 7 h ago at 0.08: decays to 0.036, below 0.05.
    try merge(db, [item("Seen yesterday", 0.9, ids: [7])], at: now.addingTimeInterval(-25 * hour))
    try merge(db, [item("Faint thing", 0.08)], at: now.addingTimeInterval(-7 * hour))
    try merge(db, [item("Oslo budget", 0.3, ids: [1])], at: now.addingTimeInterval(-hour))
    let before = try #require(try rows(db).first { $0.normKey == "oslo budget" })

    try merge(db, [item("Oslo  BUDGET!", 0.9, ids: [2, 1], kind: "task")], at: now)
    let after = try rows(db)
    #expect(after.map(\.normKey) == ["oslo budget"])
    let oslo = try #require(after.first)
    #expect(oslo.id == before.id && oslo.relevance == 0.9 && oslo.lastSeenAt == now)
    #expect(oslo.snapshotIDs == [1, 2] && oslo.addedAt == before.addedAt)
    #expect(oslo.text == "Oslo  BUDGET!" && oslo.kind == "task")

    // 40 items → the 30 most relevant.
    let many = (0..<40).map { item("Item number \($0)", 0.2 + Double($0) / 100) }
    try merge(db, many, at: now)
    let kept = try WorkingMemoryStore(db).top(100, now: now)
    #expect(kept.count == WorkingMemoryStore.maxItems && kept.count == 30)
    #expect(kept.first?.normKey == "oslo budget")
    #expect(!kept.contains { $0.normKey == "item number 10" } && kept.contains { $0.normKey == "item number 11" })
}

@Test func mergeKeepsDecayedValueWhenNewRelevanceIsLower() throws {
    let db = try AppDatabase.inMemory()
    try merge(db, [item("Oslo budget", 0.8)], at: now.addingTimeInterval(-6 * hour))
    try merge(db, [item("Oslo budget", 0.1)], at: now)
    let row = try #require(try rows(db).first)
    // max(decayed 0.4, new 0.1), re-anchored at now.
    #expect(abs(row.relevance - 0.4) < 1e-12 && row.lastSeenAt == now)
}

@Test func mergeClampsRelevanceAndKeysByTextFold() throws {
    let db = try AppDatabase.inMemory()
    try merge(db, [item("Écrire le deck", 1.7), item("Budget", -0.3), item("NaN", .nan), item("   ", 0.9),
                   item("ecrire le DECK", 0.5, ids: [3])], at: now)
    let all = try rows(db)
    // "Budget" (0) and "NaN" (0) are below the floor; "   " has no key.
    #expect(all.map(\.normKey) == ["ecrire le deck"])
    #expect(all.first?.relevance == 1 && all.first?.snapshotIDs == [3])
}

@Test func topOrdersByDecayedRelevance() throws {
    let db = try AppDatabase.inMemory()
    try merge(db, [item("Old but strong", 0.9)], at: now.addingTimeInterval(-12 * hour))  // 0.225 now
    try merge(db, [item("Fresh", 0.5), item("Fresher", 0.6)], at: now)
    #expect(try WorkingMemoryStore(db).top(2, now: now).map(\.text) == ["Fresher", "Fresh"])
    #expect(try WorkingMemoryStore(db).top(5, now: now).map(\.text) == ["Fresher", "Fresh", "Old but strong"])
}
