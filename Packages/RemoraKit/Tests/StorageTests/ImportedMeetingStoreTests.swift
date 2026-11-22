import Foundation
import Storage
import Testing

@Test func importedMeetingsReplaceTheSameSourceRecordAndStaySearchable() throws {
    let db = try AppDatabase.inMemory()
    let store = ImportedMeetingStore(db)
    let source = MeetingSource(provider: .quill, endpoint: "http://127.0.0.1:8080/mcp")
    try store.save(source)
    let now = Date()
    let generation = try DataGeneration.current(db)
    let original = ImportedMeeting(sourceID: source.id, remoteID: "meeting-1", startedAt: now,
                                   title: "Planning", body: "Original transcript")
    var edited = original
    edited.body = "Revised transcript"
    #expect(try store.write(original, source: source, generation: generation, now: now) == .saved)
    #expect(try store.write(edited, source: source, generation: generation, now: now) == .saved)
    #expect(try store.write(edited, source: source, generation: generation, now: now) == .unchanged)
    #expect(try store.search("Original").isEmpty)
    #expect(try store.search("Revised").map(\.title) == ["Planning"])
    #expect(try store.search("").count == 1)
}

@Test func forgottenMeetingStaysForgottenAcrossSyncs() throws {
    let db = try AppDatabase.inMemory()
    let store = ImportedMeetingStore(db)
    let source = MeetingSource(provider: .granola, endpoint: "https://mcp.granola.ai/mcp")
    try store.save(source)
    let now = Date()
    let meeting = ImportedMeeting(sourceID: source.id, remoteID: "meeting-1", startedAt: now,
                                  title: "Planning", body: "Original transcript")
    let generation = try DataGeneration.current(db)
    _ = try store.write(meeting, source: source, generation: generation, now: now)
    try store.forget(meeting)
    #expect(try store.write(meeting, source: source, generation: generation, now: now) == .skipped)
    #expect(try store.search("").isEmpty)
}

@Test func importedMeetingWriteHonorsPauseAndDeleteAll() throws {
    let db = try AppDatabase.inMemory()
    let store = ImportedMeetingStore(db)
    let source = MeetingSource(provider: .quill, endpoint: "http://127.0.0.1:8080/mcp")
    try store.save(source)
    let now = Date()
    let meeting = ImportedMeeting(sourceID: source.id, remoteID: "meeting-1", startedAt: now,
                                  title: "Planning", body: "Original transcript")
    let generation = try DataGeneration.current(db)
    try SettingsStore(db).pause(until: .distantFuture)
    #expect(try store.write(meeting, source: source, generation: generation, now: now) == .skipped)
    try SettingsStore(db).pause(until: nil)
    _ = try store.write(meeting, source: source, generation: generation, now: now)
    try DataReset.deleteAllCapturedData(in: db)
    #expect(try store.search("Original").isEmpty)
    #expect(try store.sources().isEmpty)
    #expect(throws: DataGeneration.Stale.self) {
        try store.write(meeting, source: source, generation: generation, now: now)
    }
}

@Test func removingMeetingChatAccessPreventsOlderChatReplay() throws {
    let db = try AppDatabase.inMemory()
    let store = ImportedMeetingStore(db)
    let now = Date()
    #expect(try !store.chatAccessEnabled())
    try store.setChatAccessEnabled(true, now: now)
    #expect(try store.chatAccessEnabled())
    try store.setChatAccessEnabled(false, now: now)
    #expect(try !store.chatAccessEnabled())
    let watermark = try db.reader.read { ForgetMarks.chatForgetAt(in: $0) }
    #expect(watermark.map { abs($0.timeIntervalSince(now)) < 0.001 } == true)
}
