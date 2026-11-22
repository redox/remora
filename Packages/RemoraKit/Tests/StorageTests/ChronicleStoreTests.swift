import Foundation
import GRDB
import Testing
@testable import Storage

private let base = Date(timeIntervalSince1970: 1_763_643_600)  // 2025-11-20 13:00 UTC

private func chron(_ level: ChronicleLevel, _ key: String, start: TimeInterval, length: TimeInterval,
                   summary: String = "s", dirty: Bool = false) -> Chronicle {
    Chronicle(level: level, periodKey: key, periodStart: base.addingTimeInterval(start),
              periodEnd: base.addingTimeInterval(start + length), summary: summary, isDirty: dirty, generatedAt: base)
}

private func put(_ db: AppDatabase, _ c: Chronicle) throws -> Chronicle {
    try db.writer.write { try ChronicleStore(db).upsert(c, in: $0) }
}

@Test func upsertReplacesByLevelAndKeyKeepingTheID() throws {
    let db = try AppDatabase.inMemory()
    let store = ChronicleStore(db)
    let first = try put(db, chron(.hour, "h1", start: 0, length: 3_600, summary: "first", dirty: true))
    var next = chron(.hour, "h1", start: 0, length: 3_600, summary: "second")
    next.metadata.highlights = ["x"]
    let second = try put(db, next)
    #expect(second.id == first.id && first.id != nil)
    let read = try #require(try store.chronicle(.hour, key: "h1"))
    #expect(read.summary == "second" && !read.isDirty && read.metadata.highlights == ["x"])
    // Same key at another level is another row.
    let day = try put(db, chron(.day, "h1", start: 0, length: 86_400))
    #expect(day.id != first.id)
    #expect(try db.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM chronicle") } == 2)
    // FTS follows the replacement.
    #expect(try store.search(["second"], levels: [.hour], since: nil, limit: 5).map(\.0.id) == [first.id])
    #expect(try store.search(["first"], levels: [.hour], since: nil, limit: 5).isEmpty)
}

@Test func markDirtyTouchesOnlyAnExistingRow() throws {
    let db = try AppDatabase.inMemory()
    let store = ChronicleStore(db)
    _ = try put(db, chron(.day, "d1", start: 0, length: 86_400))
    try db.writer.write { d in
        try store.markDirty(.day, key: "d1", in: d)
        try store.markDirty(.day, key: "missing", in: d)
    }
    #expect(try store.chronicle(.day, key: "d1")?.isDirty == true)
    #expect(try store.chronicle(.day, key: "missing") == nil)
}

@Test func childrenAreTheLowerLevelInsideThePeriod() throws {
    let db = try AppDatabase.inMemory()
    let store = ChronicleStore(db)
    let day = try put(db, chron(.day, "d", start: 0, length: 86_400))
    let h1 = try put(db, chron(.hour, "h1", start: 3_600, length: 3_600))
    let h0 = try put(db, chron(.hour, "h0", start: 0, length: 7_200))  // merged span
    _ = try put(db, chron(.hour, "next", start: 86_400, length: 3_600))
    #expect(try store.children(of: day).map(\.id) == [h0.id, h1.id])
    #expect(try store.children(of: h0).isEmpty)
    let month = try put(db, chron(.month, "m", start: 0, length: 30 * 86_400))
    _ = try put(db, chron(.week, "w", start: 0, length: 7 * 86_400))
    #expect(try store.children(of: month).map(\.id) == [day.id])
    let year = try put(db, chron(.year, "y", start: 0, length: 365 * 86_400))
    #expect(try store.children(of: year).map(\.id) == [month.id])
    let week = try #require(try store.chronicle(.week, key: "w"))
    #expect(try store.children(of: week).map(\.id) == [day.id])
}

@Test func listReturnsOverlappingRowsOfOneLevelInOrder() throws {
    let db = try AppDatabase.inMemory()
    let store = ChronicleStore(db)
    let b = try put(db, chron(.hour, "b", start: 3_600, length: 3_600))
    let a = try put(db, chron(.hour, "a", start: 0, length: 3_600))
    _ = try put(db, chron(.hour, "c", start: 7_200, length: 3_600))
    _ = try put(db, chron(.day, "d", start: 0, length: 86_400))
    let rows = try store.list(level: .hour, from: base.addingTimeInterval(1_800), to: base.addingTimeInterval(7_200))
    #expect(rows.map(\.id) == [a.id, b.id])
}

@Test func searchRanksFiltersLevelsAndSince() throws {
    let db = try AppDatabase.inMemory()
    let store = ChronicleStore(db)
    let strong = try put(db, chron(.hour, "h1", start: 0, length: 3_600, summary: "Oslo offsite budget, Oslo venue, Oslo"))
    let weak = try put(db, chron(.hour, "h2", start: 3_600, length: 3_600, summary: "Lunch, then the Oslo deck and a long afternoon of email"))
    _ = try put(db, chron(.day, "d", start: 0, length: 86_400, summary: "Oslo day"))
    _ = try put(db, chron(.hour, "h3", start: 7_200, length: 3_600, summary: "Réunion d'équipe"))
    let hits = try store.search(["oslo"], levels: [.hour], since: nil, limit: 10)
    #expect(hits.map(\.0.id) == [strong.id, weak.id])
    #expect(hits[0].1 >= hits[1].1)
    #expect(try store.search(["oslo"], levels: [.hour], since: base.addingTimeInterval(3_600), limit: 10).map(\.0.id) == [weak.id])
    #expect(try store.search(["oslo"], levels: [.hour, .day], since: nil, limit: 10).count == 3)
    #expect(try store.search(["reunion"], levels: [.hour], since: nil, limit: 10).count == 1)
    #expect(try store.search(["oslo"], levels: [], since: nil, limit: 10).isEmpty)
    #expect(try store.search(["   "], levels: [.hour], since: nil, limit: 10).isEmpty)
    #expect(try store.search(["oslo"], levels: [.hour], since: nil, limit: 1).count == 1)
}
