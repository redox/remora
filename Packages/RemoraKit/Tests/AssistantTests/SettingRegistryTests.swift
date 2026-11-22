import ChatBar
import Dictation
import Foundation
import GRDB
import Input
import Storage
import Testing
@testable import Assistant

private func get(_ db: AppDatabase, _ name: String) throws -> String {
    let e = try #require(SettingRegistry.entry(name))
    return try db.reader.read { d in try e.get(SettingsStore(db), d) }
}

private func set(_ db: AppDatabase, _ name: String, _ value: String) throws {
    let e = try #require(SettingRegistry.entry(name))
    try db.writer.write { d in try e.set(SettingsStore(db), d, value) }
}

@Suite struct SettingRegistryTests {
    @Test func registryIsExactAllowlist() {
        #expect(SettingRegistry.entries.map(\.name).sorted() == [
            "auto_hide_bar", "background_memory", "bar_position", "daily_background_budget", "dictation",
            "dim_bar_when_unfocused", "memory_language", "open_on_hover", "proactive_messages",
            "raw_capture_retention", "sounds", "text_size", "window_badge",
        ])
    }

    @Test func privacyRelevantSettingsNeedConfirmation() {
        let confirm = SettingRegistry.entries.filter { $0.risk == .confirm }.map(\.name).sorted()
        #expect(confirm == ["background_memory", "raw_capture_retention"])
        #expect(SettingRegistry.entry("exclusions") == nil)
        #expect(SettingRegistry.entry("pause") == nil)
    }

    @Test func registryRejectsBadValues() throws {
        let db = try AppDatabase.inMemory()
        try set(db, "text_size", "120")
        try set(db, "bar_position", "left")
        let before = try db.reader.read { d in try String.fetchOne(d, sql: "SELECT value FROM settings WHERE key = ?",
                                                                   arguments: [BarSettings.key]) }
        for (name, value) in [("text_size", "175"), ("text_size", "125"), ("bar_position", "middle"),
                              ("sounds", "maybe"), ("raw_capture_retention", "45"), ("daily_background_budget", "50"),
                              ("memory_language", "de")] {
            #expect(throws: SettingValueError.self) { try set(db, name, value) }
        }
        let after = try db.reader.read { d in try String.fetchOne(d, sql: "SELECT value FROM settings WHERE key = ?",
                                                                  arguments: [BarSettings.key]) }
        #expect(after == before)
        #expect(try get(db, "text_size") == "120")
        #expect(try get(db, "bar_position") == "left")
    }

    @Test func valuesRoundTripThroughTheirStores() throws {
        let db = try AppDatabase.inMemory()
        let s = SettingsStore(db)
        // Defaults.
        #expect(try get(db, "proactive_messages") == "on")
        #expect(try get(db, "background_memory") == "on")
        #expect(try get(db, "raw_capture_retention") == "30")
        #expect(try get(db, "daily_background_budget") == "750000")
        #expect(try get(db, "window_badge") == "off")
        #expect(try get(db, "text_size") == "100")

        try set(db, "proactive_messages", "off")
        try set(db, "bar_position", "bottom_right")
        try set(db, "open_on_hover", "off")
        try set(db, "auto_hide_bar", "on")
        try set(db, "dim_bar_when_unfocused", "on")
        try set(db, "text_size", "150")
        try set(db, "sounds", "off")
        try set(db, "window_badge", "on")
        try set(db, "dictation", "on")
        try set(db, "memory_language", "fr")
        try set(db, "background_memory", "off")
        try set(db, "raw_capture_retention", "forever")
        try set(db, "daily_background_budget", "2000000")

        #expect(try s.value(Bool.self, forKey: "proactive.enabled") == false)
        let bar = try #require(try s.value(BarSettings.self, forKey: BarSettings.key))
        #expect(bar.position == .bottomRight && !bar.openOnHover && bar.autoHide && bar.dimWhenUnfocused)
        #expect(bar.textScale == 1.5)
        #expect(try s.value(ShortcutSettings.self, forKey: ShortcutSettings.settingsKey)?.soundsEnabled == false)
        #expect(try s.windowBadgeEnabled())
        #expect(try s.value(DictationSettings.self, forKey: DictationSettings.settingsKey)?.enabled == true)
        let memory = MemorySettings(s)
        #expect(memory.language() == .fr)
        #expect(!memory.enabled())
        #expect(memory.retention() == .forever)
        #expect(memory.dailyTokenBudget() == 2_000_000)
    }

    @Test func changingOneFieldKeepsTheOthers() throws {
        let db = try AppDatabase.inMemory()
        var shortcuts = ShortcutSettings()
        shortcuts.chordEnabled = true
        var bar = BarSettings()
        bar.pinned = true
        try SettingsStore(db).setValue(shortcuts, forKey: ShortcutSettings.settingsKey)
        try SettingsStore(db).setValue(bar, forKey: BarSettings.key)
        try set(db, "sounds", "off")
        try set(db, "text_size", "110")
        #expect(try SettingsStore(db).value(ShortcutSettings.self, forKey: ShortcutSettings.settingsKey)?.chordEnabled == true)
        #expect(try SettingsStore(db).value(BarSettings.self, forKey: BarSettings.key)?.pinned == true)
    }
}
