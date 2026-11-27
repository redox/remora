import Foundation
import Testing
@testable import Dictation
@testable import Storage

@Test(arguments: [(["fr-FR", "en-US"], DictationLocale.fr), (["en-GB"], .en), (["de-DE", "fr-CA"], .fr), (["ja-JP"], .en)])
func systemDefault(langs: [String], expected: DictationLocale) {
    #expect(DictationLocale.systemDefault(preferredLanguages: langs) == expected)
}

@Test func localeBasics() {
    #expect(DictationLocale.fr.badge == "FR"); #expect(DictationLocale.en.name == "English")
    #expect(DictationLocale.fr.other == .en); #expect(DictationLocale.en.locale.language.languageCode?.identifier == "en"); #expect(DictationLocale.en.locale.region?.identifier == "US")
}

@Test func chooserOrderIsPinnedThenAppThenDefault() {
    var m = LocaleMemory(); m.record(.fr, for: "com.tinyspeck.slackmacgap", at: .now)
    #expect(LocaleChooser.choose(pinned: .en, appKey: "com.tinyspeck.slackmacgap", memory: m, defaultLocale: .en) == .en)
    #expect(LocaleChooser.choose(pinned: nil, appKey: "com.tinyspeck.slackmacgap", memory: m, defaultLocale: .en) == .fr)
    #expect(LocaleChooser.choose(pinned: nil, appKey: "com.apple.mail", memory: m, defaultLocale: .en) == .en)
}

@Test func memoryPrunesOldestBeyondCap() {
    var m = LocaleMemory()
    for i in 0...200 { m.record(.fr, for: "app\(i)", at: Date(timeIntervalSince1970: Double(i))) }
    #expect(m.entries.count == 200)
    #expect(m.locale(for: "app0") == nil)
    #expect(m.locale(for: "app200") == .fr)
}

@Test func memoryIgnoresNilKeyAndForgets() {
    var m = LocaleMemory(); m.record(.fr, for: nil, at: .now)
    #expect(m.entries.isEmpty); #expect(m.locale(for: nil) == nil)
    m.record(.fr, for: "a", at: .now); m.forgetAll(); #expect(m.entries.isEmpty)
}

@Test func appKeyFallsBackToName() {
    #expect(AppKey.make(bundleID: "b", appName: "Foo") == "b")
    #expect(AppKey.make(bundleID: nil, appName: "Foo") == "name:Foo")
    #expect(AppKey.make(bundleID: nil, appName: nil) == nil)
}

@Test func settingsRoundTripThroughSettingsStore() throws {
    let store = SettingsStore(try AppDatabase.inMemory())
    var s = DictationSettings(defaultLocale: .fr); s.enabled = true; s.pinnedLocale = .en
    try store.setValue(s, forKey: DictationSettings.settingsKey)
    #expect(try store.value(DictationSettings.self, forKey: DictationSettings.settingsKey) == s)
    var m = LocaleMemory(); m.record(.fr, for: "x", at: Date(timeIntervalSince1970: 5))
    try store.setValue(m, forKey: LocaleMemory.settingsKey)
    #expect(try store.value(LocaleMemory.self, forKey: LocaleMemory.settingsKey) == m)
}

@Test func settingsDecodeMissingKeysAsDefaults() throws {
    let s = try JSONDecoder().decode(DictationSettings.self, from: Data(#"{"enabled":true}"#.utf8))
    #expect(s.enabled); #expect(s.cleanupEnabled); #expect(s.pinnedLocale == nil)
    let e = try JSONDecoder().decode(DictationSettings.self, from: Data("{}".utf8))
    #expect(!e.enabled)
}

@Test func savedDictationSettingsRequireOptInToSendAudioOnStop() throws {
    let old = try JSONDecoder().decode(DictationSettings.self, from: Data(#"{"enabled":true}"#.utf8))
    #expect(!old.transcribeOnStop)
    var enabled = old
    enabled.transcribeOnStop = true
    let data = try JSONEncoder().encode(enabled)
    #expect(try JSONDecoder().decode(DictationSettings.self, from: data).transcribeOnStop)
}
