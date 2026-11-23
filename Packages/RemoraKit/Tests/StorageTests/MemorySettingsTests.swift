import Foundation
import GRDB
import Testing
@testable import Storage

@Test func settingsDefaultsAndCorruptValueFallsBack() throws {
    let db = try AppDatabase.inMemory()
    let m = MemorySettings(SettingsStore(db))
    #expect(m.enabled() == true)
    #expect(m.language() == .en)
    #expect(m.retention() == .days(30))
    #expect(m.backoff() == UsageBackoff())

    for key in [MemorySettings.enabledKey, MemorySettings.languageKey, MemorySettings.retentionKey,
                MemorySettings.backoffKey] {
        try db.writer.write {
            try $0.execute(sql: "INSERT OR REPLACE INTO settings (key, value) VALUES (?, '{')", arguments: [key])
        }
    }
    #expect(m.enabled() == true)
    #expect(m.language() == .en)
    #expect(m.retention() == .days(30))
    #expect(m.backoff() == UsageBackoff())
    // Valid JSON, unknown language: still the default.
    try SettingsStore(db).setValue("de", forKey: MemorySettings.languageKey)
    #expect(m.language() == .en)
}

@Test func memorySettingsRoundTrip() throws {
    let db = try AppDatabase.inMemory()
    let m = MemorySettings(SettingsStore(db))
    try m.setEnabled(false)
    try m.setLanguage(.fr)
    try m.setRetention(.forever)
    var b = UsageBackoff(); b.recordLimit(at: memoryT0)
    try m.setBackoff(b)
    #expect(m.enabled() == false && m.language() == .fr && m.retention() == .forever)
    #expect(m.backoff() == b)
    #expect(MemoryLanguage.en.name == "English" && MemoryLanguage.fr.name == "French")
    // Stored under the pinned keys, as JSON.
    #expect(try SettingsStore(db).value(String.self, forKey: "memory.language") == "fr")
    #expect(try SettingsStore(db).value(Bool.self, forKey: "memory.enabled") == false)

    // `in:` overloads inside a generation-checked write (F-6).
    try DataGeneration.write(db, expected: 0) { d in
        try m.setLanguage(.en, in: d)
        try m.setBackoff(UsageBackoff(), in: d)
        #expect(m.backoff(in: d) == UsageBackoff())
    }
    #expect(m.language() == .en && m.backoff() == UsageBackoff())
}

@Test func retentionIsClampedTo7Through365Days() throws {
    let db = try AppDatabase.inMemory()
    let m = MemorySettings(SettingsStore(db))
    try m.setRetention(.days(2))
    #expect(m.retention() == .days(7))
    try m.setRetention(.days(9_999))
    #expect(m.retention() == .days(365))
    // A stored out-of-range value (older build, hand edit) is clamped on read.
    try SettingsStore(db).setValue(RetentionSetting.days(1), forKey: MemorySettings.retentionKey)
    #expect(m.retention() == .days(7))
    #expect(RetentionSetting.days(clamping: 90) == .days(90))
}

