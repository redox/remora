import Foundation
import GRDB
import Testing
@testable import Storage

private let expectedDefaults = [
    "app:Claude", "app:ChatGPT", "app:Cursor", "claude.ai", "chatgpt.com", "chat.openai.com",
    "app:Alacritty", "app:Ghostty", "app:iTerm2", "app:Terminal",
]

@Test func seedsDefaultsOnce() throws {
    let db = try AppDatabase.inMemory(); let store = ExclusionStore(db)
    #expect(ExclusionStore.defaultPatterns == expectedDefaults)
    #expect(try store.seedDefaults() == true)
    #expect(try store.all() == expectedDefaults)
    #expect(try store.seedDefaults() == false)
    #expect(try store.all() == expectedDefaults)
}

@Test func removedDefaultStaysRemoved() throws {
    let db = try AppDatabase.inMemory(); let store = ExclusionStore(db)
    try store.seedDefaults()
    try store.remove("app:Cursor")
    try store.seedDefaults()
    #expect(!(try store.all()).contains("app:Cursor"))
    #expect(try store.all().count == expectedDefaults.count - 1)
}

@Test func existingUserEntriesUntouchedAndPreexistingDefaultsNotDuplicated() throws {
    let db = try AppDatabase.inMemory(); let store = ExclusionStore(db)
    // Like the user's live DB: their own rules plus the defaults already inserted by hand.
    try store.add("intranet.example.com")
    try store.add("app:Claude")
    try store.add("app:Terminal")
    try store.seedDefaults()
    let all = try store.all()
    #expect(all.prefix(3) == ["intranet.example.com", "app:Claude", "app:Terminal"])
    #expect(Set(all) == Set(expectedDefaults + ["intranet.example.com"]))
    #expect(all.count == expectedDefaults.count + 1)
}
