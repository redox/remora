import Foundation
import Storage
import Testing
@testable import Capture

@Test func manualSavesRequirePermissionFromEveryMatchingExclusion() throws {
    let db = try AppDatabase.inMemory()
    let exclusions = ExclusionStore(db)
    let notes = RememberedNotes(db)
    let context = ctx(app: "Claude", bundleID: "example.claude", title: "Private project")
    try exclusions.add("app:Claude")
    #expect(try !notes.allowsSelection(from: context))
    try exclusions.setManualSaves(true, for: "app:Claude")
    #expect(try notes.allowsSelection(from: context))
    #expect(!SnapshotPolicy.current(db).shouldCapture(context))

    try exclusions.add("title:Private")
    #expect(try !notes.allowsSelection(from: context))
    #expect(try !notes.allowsSelection(from: ctx(app: "Claude", bundleID: "example.claude", privateBrowsing: true)))
    #expect(try !notes.allowsSelection(from: ctx(app: "Safari", bundleID: "com.apple.Safari")))
}

@Test func savingRechecksTheIgnoreRuleAfterPreview() throws {
    let db = try AppDatabase.inMemory()
    let store = ExclusionStore(db)
    let notes = RememberedNotes(db)
    let source = ctx(app: "Cursor", bundleID: "example.cursor")
    try store.add("app:Cursor")
    try store.setManualSaves(true, for: "app:Cursor")
    #expect(try notes.allowsSelection(from: source))
    let generation = try DataGeneration.current(db)
    try store.setManualSaves(false, for: "app:Cursor")
    #expect(throws: RememberedNotes.Refusal.sourceUnavailable) {
        try notes.save("Keep the API working", annotation: "", from: source, generation: generation)
    }
    #expect(try SavedNoteStore(db).list().isEmpty)
}

@Test func browserManualSavesStillHonorSiteAndLocationRules() throws {
    let db = try AppDatabase.inMemory()
    let store = ExclusionStore(db)
    let notes = RememberedNotes(db)
    let safari = "com.apple.Safari"
    let site = ctx(bundleID: safari, url: "https://chatgpt.com/example")
    try store.add("chatgpt.com")
    try store.setManualSaves(true, for: "chatgpt.com")
    #expect(try notes.allowsSelection(from: site))
    #expect(try !notes.allowsSelection(from: ctx(bundleID: safari, url: "https://chatgpt.com/login")))
    #expect(try !notes.allowsSelection(from: ctx(bundleID: safari, url: "about:blank")))
    try store.add("path:private")
    #expect(try !notes.allowsSelection(from: ctx(bundleID: safari, url: "file:///Users/me/private/notes.txt")))
}

@Test func savingRedactsAndIndexesOnlyTheEditedExcerptAndAnnotation() throws {
    let db = try AppDatabase.inMemory()
    let notes = RememberedNotes(db)
    let generation = try DataGeneration.current(db)
    let saved = try notes.save(" Keep the legacy API (4111 1111 1111 1111) ", annotation: " Migration constraint ",
                              generation: generation)
    #expect(saved.text == "Keep the legacy API ([redacted])")
    #expect(saved.annotation == "Migration constraint")
    #expect(try SavedNoteStore(db).list(query: "migration").map(\.id) == [saved.id])
    #expect(try SavedNoteStore(db).list(query: "4111").isEmpty)
}

@Test func deletingAllDataInvalidatesOpenNotePreviews() throws {
    let db = try AppDatabase.inMemory()
    let notes = RememberedNotes(db)
    let generation = try DataGeneration.current(db)
    try DataReset.deleteAllCapturedData(in: db)
    #expect(throws: DataGeneration.Stale.self) {
        try notes.save("A note drafted before delete all", annotation: "", generation: generation)
    }
}

@Test func pausingCaptureBlocksSourceSelectionsButAllowsExplicitPaste() throws {
    let db = try AppDatabase.inMemory()
    try SettingsStore(db).pause(until: .distantFuture)
    let notes = RememberedNotes(db)
    let source = ctx(app: "Notes", bundleID: "com.apple.Notes")
    let generation = try DataGeneration.current(db)
    #expect(try !notes.allowsSelection(from: source))
    #expect(throws: RememberedNotes.Refusal.sourceUnavailable) {
        try notes.save("Selection", annotation: "", from: source, generation: generation)
    }
    #expect(try notes.save("Pasted text", annotation: "", generation: generation).text == "Pasted text")
}
