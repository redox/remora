import Foundation
import GRDB
import Testing
@testable import Storage

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private func record(_ db: AppDatabase, surface: String = "app:x", lines: [String]) throws {
    let sample = BoilerplateSample(surface: surface, lines: Dictionary(uniqueKeysWithValues: lines.map { ("h-" + $0, $0) }))
    try db.writer.write { d in try BoilerplateStore.record(sample, in: d) }
}

@Test func learnsAt80PercentAfter20Docs() throws {
    let db = try AppDatabase.inMemory()
    for i in 0..<25 {
        var lines = ["Other \(i)"]
        if i < 21 { lines.append("Hide sidebar") }
        if i < 19 { lines.append("Search") }
        try record(db, lines: lines)
    }
    let store = BoilerplateStore(db)
    #expect(try store.surfacesNeedingFirstFit() == ["app:x"])
    let r = try store.refresh(surface: "app:x", at: t0)
    #expect(r.learned == 1 && r.forgotten == 0)
    #expect(try store.learned(surface: "app:x") == ["h-Hide sidebar"])
    #expect(try store.surfacesNeedingFirstFit().isEmpty)
}

@Test func learnsNothingBelow20Docs() throws {
    let db = try AppDatabase.inMemory()
    for _ in 0..<19 { try record(db, lines: ["Hide sidebar"]) }
    let store = BoilerplateStore(db)
    #expect(try store.surfacesNeedingFirstFit().isEmpty)
    #expect(try store.refresh(surface: nil, at: t0).learned == 0)
    #expect(try store.learned(surface: "app:x").isEmpty)
}

@Test func forgetsBelow60Percent() throws {
    let db = try AppDatabase.inMemory()
    for _ in 0..<20 { try record(db, lines: ["Hide sidebar"]) }
    let store = BoilerplateStore(db)
    #expect(try store.refresh(surface: nil, at: t0).learned == 1)
    // 20 more docs without the line: share 20/40 = 50 % < 60 %.
    for i in 0..<20 { try record(db, lines: ["Other \(i)"]) }
    let r = try store.refresh(surface: "app:x", at: t0.addingTimeInterval(60))
    #expect(r.forgotten == 1 && r.learned == 0)
    #expect(try store.learned(surface: "app:x").isEmpty)
}

@Test func keepsBetween60And80Percent() throws {
    let db = try AppDatabase.inMemory()
    for _ in 0..<20 { try record(db, lines: ["Hide sidebar"]) }
    let store = BoilerplateStore(db)
    _ = try store.refresh(surface: nil, at: t0)
    // 20 of 28 = 71 %: neither learned anew nor forgotten.
    for i in 0..<8 { try record(db, lines: ["Other \(i)"]) }
    let r = try store.refresh(surface: nil, at: t0.addingTimeInterval(60))
    #expect(r.forgotten == 0 && r.learned == 0)
    #expect(try store.learned(surface: "app:x") == ["h-Hide sidebar"])
}

@Test func halvesCountsAbove200DocsAndPrunesDecayedRows() throws {
    let db = try AppDatabase.inMemory()
    for i in 0..<201 { try record(db, lines: i == 0 ? ["Rare", "Hide sidebar"] : ["Hide sidebar"]) }
    let store = BoilerplateStore(db)
    _ = try store.refresh(surface: nil, at: t0)
    let (docs, stats, rare) = try db.reader.read { d in
        (try Double.fetchOne(d, sql: "SELECT docs FROM boilerplate_surfaces")!,
         try Double.fetchOne(d, sql: "SELECT docs FROM boilerplate_stats WHERE line_hash = 'h-Hide sidebar'")!,
         try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM boilerplate_stats WHERE line_hash = 'h-Rare'")!)
    }
    #expect(docs == 100.5 && stats == 100.5)
    #expect(rare == 0)  // F-25: 1 -> 0.5 < 1 is deleted
}

@Test func rolledUpdateDoesNotCountAsDoc() throws {
    let db = try AppDatabase.inMemory()
    let store = SnapshotStore(db)
    let sample = BoilerplateSample(surface: "app:Notes", lines: ["h": "Hide sidebar"])
    let base = "Line one of the notes\nLine two of the notes\nLine three of the notes"
    let first = Snapshot.fixture(text: base, capturedAt: t0)
    #expect(try store.upsertUnlessPaused(first, now: t0, sample: sample) != nil)
    let grown = Snapshot.fixture(text: base + "\nLine four", capturedAt: t0.addingTimeInterval(30))
    #expect(try store.upsertUnlessPaused(grown, now: t0.addingTimeInterval(30), sample: sample) != nil)
    let (rows, docs, line) = try db.reader.read { d in
        (try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM snapshots")!,
         try Double.fetchOne(d, sql: "SELECT docs FROM boilerplate_surfaces WHERE surface = 'app:Notes'")!,
         try Double.fetchOne(d, sql: "SELECT docs FROM boilerplate_stats WHERE line_hash = 'h'")!)
    }
    #expect(rows == 1 && docs == 1 && line == 1)
}

@Test func pausedUpsertRecordsNoSample() throws {
    let db = try AppDatabase.inMemory()
    try SettingsStore(db).pause(until: .distantFuture)
    let sample = BoilerplateSample(surface: "app:Notes", lines: ["h": "Hide sidebar"])
    #expect(try SnapshotStore(db).upsertUnlessPaused(.fixture(text: "abc def", capturedAt: t0), now: t0, sample: sample) == nil)
    #expect(try db.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM boilerplate_surfaces")! } == 0)
}
