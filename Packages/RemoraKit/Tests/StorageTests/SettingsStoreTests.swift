import Foundation
import Testing
@testable import Storage

@Test func pauseLifecycle() throws {
    let s = SettingsStore(try .inMemory()); let now = Date()
    #expect(try !s.isPaused(now: now))
    try s.pause(until: now + 900); #expect(try s.isPaused(now: now)); #expect(try !s.isPaused(now: now + 901))
    try s.pause(until: .distantFuture); #expect(try s.isPaused(now: now + 1e9))
    try s.pause(until: nil); #expect(try !s.isPaused(now: now))
    #expect(try s.pausedUntil() == nil)
}

@Test func pausedUntilRoundTrips() throws {
    let s = SettingsStore(try .inMemory()); let t = Date(timeIntervalSince1970: 1_800_000_000.5)
    try s.pause(until: t)
    #expect(try s.pausedUntil() == t)
}

@Test func exclusionStoreAddRemoveIdempotent() throws {
    let s = ExclusionStore(try .inMemory())
    try s.add("  app:Slack "); try s.add("app:Slack"); try s.add("intranet.example.com")
    #expect(try s.all() == ["app:Slack", "intranet.example.com"])
    try s.remove("app:Slack")
    #expect(try s.all() == ["intranet.example.com"])
}

@Test func exclusionStoreRejectsMalformed() throws {
    let s = ExclusionStore(try .inMemory())
    #expect(throws: ExclusionStore.InvalidPattern.self) { try s.add("app:") }
    #expect(throws: ExclusionStore.InvalidPattern.self) { try s.add("   ") }
    #expect(try s.all().isEmpty)
}

@Test func corruptPauseValueThrows() throws {
    let db = try AppDatabase.inMemory()
    try db.writer.write {
        try $0.execute(sql: "INSERT OR REPLACE INTO settings (key, value) VALUES ('pausedUntil', 'garbage')")
    }
    let store = SettingsStore(db)
    #expect(throws: SettingsStore.CorruptValue.self) { try store.pausedUntil() }
    #expect(throws: SettingsStore.CorruptValue.self) { try store.isPaused(now: Date()) }
}

@Test func removeWorksForStoredPatternWithInvisibleCharacters() throws {
    let store = ExclusionStore(try .inMemory())
    let raw = "app:\u{200E}WhatsApp"  // as stored by an older build
    try store.add(raw)
    #expect(try store.all() == [raw])
    try store.remove(try store.all()[0])  // the UI removes by the listed stored string
    #expect(try store.all().isEmpty)
}

@Test func windowBadgeDefaultsOffAndRoundTrips() throws {
    let s = SettingsStore(try .inMemory())
    #expect(try !s.windowBadgeEnabled())
    try s.setWindowBadgeEnabled(true); #expect(try s.windowBadgeEnabled())
    try s.setWindowBadgeEnabled(false); #expect(try !s.windowBadgeEnabled())
}

@Test func corruptBadgeValueThrows() throws {
    let db = try AppDatabase.inMemory()
    try db.writer.write { d in
        try d.execute(sql: "INSERT INTO settings (key, value) VALUES ('windowBadgeEnabled', 'maybe')")
    }
    #expect(throws: SettingsStore.CorruptValue(key: "windowBadgeEnabled")) {
        try SettingsStore(db).windowBadgeEnabled()
    }
}
