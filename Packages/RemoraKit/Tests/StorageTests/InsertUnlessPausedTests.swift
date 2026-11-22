import Foundation
import GRDB
import Testing
@testable import Storage

private let now = Date(timeIntervalSince1970: 2_000_000)

@Test func insertUnlessPausedInsertsWhenNotPaused() throws {
    let db = try AppDatabase.inMemory(); let store = SnapshotStore(db)
    let s = try store.insertUnlessPaused(.fixture(text: "hello"), now: now)
    #expect(s?.id != nil)
    try SettingsStore(db).pause(until: now - 1)  // expired pause
    #expect(try store.insertUnlessPaused(.fixture(text: "again"), now: now) != nil)
}

@Test func insertUnlessPausedSkipsWhenPaused() throws {
    let db = try AppDatabase.inMemory(); let store = SnapshotStore(db)
    try SettingsStore(db).pause(until: .distantFuture)
    #expect(try store.insertUnlessPaused(.fixture(text: "hello"), now: now) == nil)
    #expect(try store.recent(limit: 5).isEmpty)
}

@Test func insertUnlessPausedTreatsCorruptPauseAsPaused() throws {
    let db = try AppDatabase.inMemory(); let store = SnapshotStore(db)
    try db.writer.write {
        try $0.execute(sql: "INSERT OR REPLACE INTO settings (key, value) VALUES ('pausedUntil', 'garbage')")
    }
    #expect(try store.insertUnlessPaused(.fixture(text: "hello"), now: now) == nil)
    #expect(try store.recent(limit: 5).isEmpty)
}

@Test func recordFocusUnlessPausedSkipsWhenPaused() throws {
    let db = try AppDatabase.inMemory(); let a = ActivityStore(db)
    try SettingsStore(db).pause(until: .distantFuture)
    #expect(try a.recordFocus(app: "X", bundleID: nil, windowTitle: nil, domain: nil,
                              at: now, unlessPausedAt: now) == false)
    #expect(try a.events(since: .distantPast).isEmpty)
}
