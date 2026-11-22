import Foundation
import GRDB
import Storage
import Testing
@testable import Capture

final class FakeReader: WindowReading {
    let context: WindowContext
    let text: Mutex2<String>
    private let count = Mutex2<Int>(0)
    var readCount: Int { count.get() }
    init(_ context: WindowContext, _ text: String) {
        self.context = context; self.text = Mutex2(text)
    }
    func setText(_ t: String) { text.set(t) }
    func readFrontmost() async throws -> (context: WindowContext, text: String)? {
        count.set(count.get() + 1)
        return (context, text.get())
    }
}

final class Mutex2<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock(); private var v: T
    init(_ v: T) { self.v = v }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return v }
    func set(_ n: T) { lock.lock(); v = n; lock.unlock() }
}

final class CountingHangingReader: WindowReading {
    private let count = Mutex2<Int>(0)
    var startCount: Int { count.get() }
    func readFrontmost() async throws -> (context: WindowContext, text: String)? {
        count.set(count.get() + 1)
        await Task.detached { try? await Task.sleep(for: .seconds(5)) }.value
        return nil
    }
}

struct ThrowingReader: WindowReading {
    struct Boom: Error {}
    func readFrontmost() async throws -> (context: WindowContext, text: String)? { throw Boom() }
}

struct HangingReader: WindowReading {
    func readFrontmost() async throws -> (context: WindowContext, text: String)? {
        // Ignores cancellation on purpose, like a stuck AX IPC call.
        await Task.detached { try? await Task.sleep(for: .seconds(5)) }.value
        return nil
    }
}

private let longText = "Ma carte 4111 1111 1111 1111 pour le voyage à Oslo"
private let plain = "Quarterly planning notes for the Oslo trip itinerary"

@Test func storesRedactedSnapshot() async throws {
    let db = try AppDatabase.inMemory()
    let e = CaptureEngine(reader: FakeReader(ctx(app: "Notes"), longText), db: db)
    guard case .stored(let id) = await e.tick() else { Issue.record("not stored"); return }
    let s = try SnapshotStore(db).snapshots(ids: [id])[0]
    #expect(s.text.contains("[redacted]") && !s.text.contains("4111"))
    #expect(s.source == .ax)
}

@Test func secondIdenticalTickIsUnchanged() async throws {
    let db = try AppDatabase.inMemory()
    let reader = FakeReader(ctx(app: "Notes"), plain)
    let e = CaptureEngine(reader: reader, db: db)
    guard case .stored = await e.tick() else { Issue.record("not stored"); return }
    #expect(await e.tick() == .unchanged)
    reader.setText("  Quarterly planning   notes for the\nOslo trip itinerary \n")
    #expect(await e.tick() == .unchanged)
    reader.setText(plain + " and budget review")
    guard case .stored = await e.tick() else { Issue.record("changed text not stored"); return }
}

@Test func pausedSkipsReading() async throws {
    let db = try AppDatabase.inMemory()
    try SettingsStore(db).pause(until: .distantFuture)
    let reader = FakeReader(ctx(app: "Notes"), plain)
    let e = CaptureEngine(reader: reader, db: db)
    #expect(await e.tick() == .paused)
    #expect(reader.readCount == 0)
}

@Test func excludedContextNotStoredButFocusRecorded() async throws {
    let db = try AppDatabase.inMemory()
    try ExclusionStore(db).add("app:Notes")
    let e = CaptureEngine(
        reader: FakeReader(ctx(app: "Notes", bundleID: "com.apple.Notes", title: "Secret plan",
                               url: "https://secret.example.com/x"), plain), db: db)
    #expect(await e.tick() == .excluded)
    #expect(try SnapshotStore(db).recent(limit: 10).isEmpty)
    let events = try ActivityStore(db).events(since: .distantPast)
    #expect(events.count == 1)
    #expect(events[0].app == "Notes" && events[0].bundleID == "com.apple.Notes")
    #expect(events[0].windowTitle == nil)
    #expect(events[0].domain == nil)
}

@Test func allowedContextRecordsFocusWithTitleAndDomain() async throws {
    let db = try AppDatabase.inMemory()
    let e = CaptureEngine(
        reader: FakeReader(ctx(app: "Safari", title: "News", url: "https://example.com/a"), plain), db: db)
    guard case .stored = await e.tick() else { Issue.record("not stored"); return }
    let events = try ActivityStore(db).events(since: .distantPast)
    #expect(events.count == 1 && events[0].windowTitle == "News" && events[0].domain == "example.com")
}

@Test func shortTextSkipped() async throws {
    let db = try AppDatabase.inMemory()
    let e = CaptureEngine(reader: FakeReader(ctx(app: "Notes"), "ok"), db: db)
    #expect(await e.tick() == .tooShort)
    #expect(try SnapshotStore(db).recent(limit: 10).isEmpty)
}

@Test func noWindowWhenReaderReturnsNil() async throws {
    struct NilReader: WindowReading {
        func readFrontmost() async throws -> (context: WindowContext, text: String)? { nil }
    }
    let e = CaptureEngine(reader: NilReader(), db: try .inMemory())
    #expect(await e.tick() == .noWindow)
}

@Test func tickTimesOutOnHungReader() async throws {
    let db = try AppDatabase.inMemory()
    let e = CaptureEngine(reader: HangingReader(), db: db, readTimeout: .milliseconds(200))
    let clock = ContinuousClock(); let start = clock.now
    #expect(await e.tick() == .timedOut)
    #expect(clock.now - start < .milliseconds(600))
    #expect(try SnapshotStore(db).recent(limit: 10).isEmpty)
}

@Test func consecutiveTicksOnHungReaderBothTimeOut() async throws {
    let e = CaptureEngine(reader: HangingReader(), db: try .inMemory(), readTimeout: .milliseconds(200))
    let clock = ContinuousClock(); let start = clock.now
    #expect(await e.tick() == .timedOut)
    #expect(await e.tick() == .timedOut)
    #expect(clock.now - start < .milliseconds(1200))
}

@Test func clipboardStoredWithSourceClipboard() async throws {
    let db = try AppDatabase.inMemory()
    let e = CaptureEngine(reader: FakeReader(ctx(app: "Notes"), plain), db: db)
    let c = ctx(app: "Notes", title: "Doc")
    guard case .stored(let id) = await e.storeClipboard(text: longText, context: c) else {
        Issue.record("not stored"); return
    }
    let s = try SnapshotStore(db).snapshots(ids: [id])[0]
    #expect(s.source == .clipboard && s.text.contains("[redacted]") && !s.text.contains("4111"))
    #expect(await e.storeClipboard(text: longText, context: c) == .unchanged)
    #expect(try ActivityStore(db).events(since: .distantPast).isEmpty)
}

@Test func clipboardAndWindowDoNotDedupeEachOther() async throws {
    let db = try AppDatabase.inMemory()
    let c = ctx(app: "Notes", title: "Doc")
    let e = CaptureEngine(reader: FakeReader(c, plain), db: db)
    guard case .stored = await e.tick() else { Issue.record("window not stored"); return }
    guard case .stored = await e.storeClipboard(text: plain, context: c) else {
        Issue.record("clipboard deduped against window"); return
    }
}

@Test func clipboardRespectsPauseAndExclusions() async throws {
    let db = try AppDatabase.inMemory()
    let e = CaptureEngine(reader: FakeReader(ctx(app: "Notes"), plain), db: db)
    try ExclusionStore(db).add("app:Notes")
    #expect(await e.storeClipboard(text: plain, context: ctx(app: "Notes")) == .excluded)
    try SettingsStore(db).pause(until: .distantFuture)
    #expect(await e.storeClipboard(text: plain, context: ctx(app: "Mail")) == .paused)
    #expect(try SnapshotStore(db).recent(limit: 10).isEmpty)
}

@Test func threeTicksOnHungReaderStartOneRead() async throws {
    let reader = CountingHangingReader()
    let e = CaptureEngine(reader: reader, db: try .inMemory(), readTimeout: .milliseconds(100))
    #expect(await e.tick() == .timedOut)
    #expect(await e.tick() == .timedOut)
    #expect(await e.tick() == .timedOut)
    #expect(reader.startCount == 1)
}

@Test func throwingReaderIsFailed() async throws {
    let e = CaptureEngine(reader: ThrowingReader(), db: try .inMemory())
    #expect(await e.tick() == .failed)
}

@Test func unwritableDatabaseIsFailed() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "remora-\(UUID().uuidString)")
    let url = dir.appending(path: "r.sqlite")
    _ = try AppDatabase.open(at: url)
    let ro = try AppDatabase.openReadOnly(at: url)
    let e = CaptureEngine(reader: FakeReader(ctx(app: "Notes"), plain), db: ro)
    #expect(await e.tick() == .failed)
}

@Test func unreadablePauseStateFailsClosed() async throws {
    let db = try AppDatabase.inMemory()
    try await db.writer.write {
        try $0.execute(sql: "INSERT OR REPLACE INTO settings (key, value) VALUES ('pausedUntil', 'garbage')")
    }
    let reader = FakeReader(ctx(app: "Notes"), plain)
    let e = CaptureEngine(reader: reader, db: db)
    #expect(await e.tick() == .paused)
    #expect(reader.readCount == 0)
    #expect(await e.storeClipboard(text: plain, context: ctx(app: "Notes")) == .paused)
}

@Test func unreadableExclusionsFailClosed() async throws {
    let db = try AppDatabase.inMemory()
    try await db.writer.write { try $0.execute(sql: "DROP TABLE exclusions") }
    let e = CaptureEngine(reader: FakeReader(ctx(app: "Notes", title: "T"), plain), db: db)
    #expect(await e.tick() == .excluded)
    #expect(await e.storeClipboard(text: plain, context: ctx(app: "Notes")) == .excluded)
    #expect(try SnapshotStore(db).recent(limit: 10).isEmpty)
    let ev = try ActivityStore(db).events(since: .distantPast)
    #expect(ev.count == 1 && ev[0].windowTitle == nil)
}

@Test func pauseEngagedDuringReadIsHonored() async throws {
    let db = try AppDatabase.inMemory()
    struct PausingReader: WindowReading {
        let db: AppDatabase
        func readFrontmost() async throws -> (context: WindowContext, text: String)? {
            try SettingsStore(db).pause(until: .distantFuture)
            return (WindowContext(app: "Notes"), "Quarterly planning notes for the Oslo trip itinerary")
        }
    }
    let e = CaptureEngine(reader: PausingReader(db: db), db: db)
    #expect(await e.tick() == .paused)
    #expect(try SnapshotStore(db).recent(limit: 10).isEmpty)
}

// MARK: - Titles and URLs are redacted before any write (final review, Critical)

@Test func titleAndURLRedactedInSnapshotsAndActivity() async throws {
    let db = try AppDatabase.inMemory()
    let c = ctx(app: "Safari", bundleID: "com.apple.Safari",
                title: "Reset password – token=abc123def456ghi789",
                url: "https://zoom.us/j/123?pwd=SeCrEt123")
    let e = CaptureEngine(reader: FakeReader(c, plain), db: db)
    guard case .stored(let id) = await e.tick() else { Issue.record("not stored"); return }
    let s = try SnapshotStore(db).snapshots(ids: [id])[0]
    #expect(s.windowTitle == "Reset password – token=[redacted]")
    #expect(s.url == "https://zoom.us/j/123?pwd=[redacted]")
    #expect(s.domain == "zoom.us")
    let ev = try ActivityStore(db).events(since: .distantPast)
    #expect(ev.count == 1)
    #expect(ev[0].windowTitle == "Reset password – token=[redacted]")
    #expect(ev[0].domain == "zoom.us")
    // Nothing anywhere in the database still holds the secrets.
    let dump: [String] = try await db.reader.read { d in
        try String.fetchAll(d, sql: """
            SELECT coalesce(window_title,'') || ' ' || coalesce(url,'') || ' ' || text FROM snapshots
            UNION ALL SELECT coalesce(window_title,'') FROM activity_events
            """)
    }
    #expect(!dump.joined().contains("abc123def456ghi789"))
    #expect(!dump.joined().contains("SeCrEt123"))
}

@Test func urlFragmentTokenRedacted() async throws {
    let db = try AppDatabase.inMemory()
    let c = ctx(app: "Safari", title: "Callback",
                url: "https://app.example.com/cb#access_token=ya29.SECRETVALUE&token_type=bearer")
    let e = CaptureEngine(reader: FakeReader(c, plain), db: db)
    guard case .stored(let id) = await e.tick() else { Issue.record("not stored"); return }
    let s = try SnapshotStore(db).snapshots(ids: [id])[0]
    #expect(s.url == "https://app.example.com/cb#access_token=[redacted]&token_type=bearer")
}

@Test func clipboardTitleAndURLRedacted() async throws {
    let db = try AppDatabase.inMemory()
    let e = CaptureEngine(reader: FakeReader(ctx(app: "Notes"), plain), db: db)
    let c = ctx(app: "Safari", title: "DB_PASSWORD=hunter2 - notes", url: "https://x.com/a?token=abcdef")
    guard case .stored(let id) = await e.storeClipboard(text: plain, context: c) else {
        Issue.record("not stored"); return
    }
    let s = try SnapshotStore(db).snapshots(ids: [id])[0]
    #expect(s.windowTitle == "DB_PASSWORD=[redacted]")  // unquoted labeled value: to end of line
    #expect(s.url == "https://x.com/a?token=[redacted]")
}

@Test func browserWithoutURLStoresNoTextAndRecordsAppOnlyFocus() async throws {
    let db = try AppDatabase.inMemory()
    let c = ctx(app: "Chrome", bundleID: "com.google.Chrome", title: "Private stuff")
    let e = CaptureEngine(reader: FakeReader(c, plain), db: db)
    #expect(await e.tick() == .excluded)
    #expect(try SnapshotStore(db).recent(limit: 10).isEmpty)
    let ev = try ActivityStore(db).events(since: .distantPast)
    #expect(ev.count == 1 && ev[0].app == "Chrome" && ev[0].windowTitle == nil && ev[0].domain == nil)
}

// MARK: - Rolling per-window snapshot (final review #4)

@Test func growingWindowRollsIntoOneSnapshot() async throws {
    let db = try AppDatabase.inMemory()
    let c = ctx(app: "Messages", title: "Ana")
    let reader = FakeReader(c, "hello ana how are you\nare we still on for lunch today")
    let e = CaptureEngine(reader: reader, db: db)
    guard case .stored(let id1) = await e.tick() else { Issue.record("not stored"); return }
    reader.setText("hello ana how are you\nare we still on for lunch today\nyes at noon")
    guard case .stored(let id2) = await e.tick() else { Issue.record("not stored"); return }
    #expect(id1 == id2)
    #expect(try SnapshotStore(db).recent(limit: 10).count == 1)
    #expect(try SnapshotStore(db).snapshots(ids: [id1])[0].text.hasSuffix("yes at noon"))
}

@Test func verdictSeesRuleAddedAfterInit() async throws {
    let db = try AppDatabase.inMemory()
    let e = CaptureEngine(reader: FakeReader(ctx(app: "Notes"), "x"), db: db)
    #expect(await e.verdict(for: ctx(app: "Notes")) == .allowed)
    try ExclusionStore(db).add("app:Notes")
    #expect(await e.verdict(for: ctx(app: "Notes")) == .userExcluded(pattern: "app:Notes"))
}

@Test func verdictIsRulesUnavailableWhenExclusionsUnreadable() async throws {
    let db = try AppDatabase.inMemory()
    try await db.writer.write { try $0.execute(sql: "DROP TABLE exclusions") }
    let e = CaptureEngine(reader: FakeReader(ctx(app: "Notes"), "x"), db: db)
    #expect(await e.verdict(for: ctx(app: "Notes")) == .rulesUnavailable)
    #expect(await e.appVerdict(for: ctx(app: "Notes")) == .rulesUnavailable)
}

@Test func appVerdictSeesAppRuleForBrowser() async throws {
    let db = try AppDatabase.inMemory()
    let safari = ctx(app: "Safari", bundleID: "com.apple.Safari")
    let e = CaptureEngine(reader: FakeReader(safari, "x"), db: db)
    #expect(await e.appVerdict(for: safari) == .allowed)
    try ExclusionStore(db).add("app:Safari")
    #expect(await e.appVerdict(for: safari) == .userExcluded(pattern: "app:Safari"))
}

// MARK: - Boilerplate

private let sidebarApp = "com.anthropic.claudefordesktop"
private let surface = "app:" + sidebarApp

private func learn(_ db: AppDatabase, _ lines: [String]) throws {
    try db.writer.write { d in
        for l in lines {
            try d.execute(sql: "INSERT INTO boilerplate (surface, line_hash, line_text, learned_at) VALUES (?,?,?,?)",
                          arguments: [surface, BoilerplateLine.hash(l), l, Date()])
        }
    }
}

private func surfaceDocs(_ db: AppDatabase) throws -> Double? {
    try db.reader.read { d in
        try Double.fetchOne(d, sql: "SELECT docs FROM boilerplate_surfaces WHERE surface = ?", arguments: [surface])
    }
}

private func statDocs(_ db: AppDatabase) throws -> Double? {
    try db.reader.read { d in
        try Double.fetchOne(d, sql: "SELECT docs FROM boilerplate_stats WHERE surface = ? AND line_text = 'Hide sidebar'",
                            arguments: [surface])
    }
}

private func dropStats(_ db: AppDatabase) throws {
    try db.writer.write { try $0.execute(sql: "DROP TABLE boilerplate_stats") }
}

@Test func engineStripsBeforeStorage() async throws {
    let db = try AppDatabase.inMemory()
    try learn(db, ["Hide sidebar"])
    let context = ctx(app: "Claude", bundleID: sidebarApp)
    let e = CaptureEngine(reader: FakeReader(context, "Hide sidebar\nMeeting with Marc on the Oslo itinerary"), db: db)
    guard case .stored(let id) = await e.tick() else { Issue.record("not stored"); return }
    let text = try SnapshotStore(db).snapshots(ids: [id])[0].text
    #expect(!text.contains("Hide sidebar") && text.contains("Oslo itinerary"))
    // Clipboard text with the same line keeps it, and is never sampled.
    guard case .stored(let cid) = await e.storeClipboard(
        text: "Hide sidebar\nCopied paragraph about the budget", context: context) else { Issue.record("clip"); return }
    #expect(try SnapshotStore(db).snapshots(ids: [cid])[0].text.contains("Hide sidebar"))
    #expect(try surfaceDocs(db) == 1)  // only the AX capture sampled
}

@Test func engineLearnsFromSamplesAndUnlearnedTextIsUntouched() async throws {
    let db = try AppDatabase.inMemory()
    let reader = FakeReader(ctx(app: "Claude", bundleID: sidebarApp), "x")
    let e = CaptureEngine(reader: reader, db: db)
    reader.setText("Hide sidebar\nPlain first document body text")
    guard case .stored(let id) = await e.tick() else { Issue.record("not stored"); return }
    #expect(try SnapshotStore(db).snapshots(ids: [id])[0].text.contains("Hide sidebar"))
    #expect(try surfaceDocs(db) == 1)
    #expect(try statDocs(db) == 1)
}

@Test func labelLineStrippedAfterRedactionStillRedactsItsValue() async throws {
    let db = try AppDatabase.inMemory()
    try learn(db, ["Password:"])
    let e = CaptureEngine(reader: FakeReader(ctx(app: "Claude", bundleID: sidebarApp),
                                             "Password:\ncorrect horse battery staple\nA normal sentence of enough length"), db: db)
    guard case .stored(let id) = await e.tick() else { Issue.record("not stored"); return }
    let text = try SnapshotStore(db).snapshots(ids: [id])[0].text
    #expect(text.contains("[redacted]") && !text.contains("Password:") && !text.contains("correct horse"))
}

@Test func learnedLinesSurviveDeleteAllOnlyAsRelearned() async throws {
    let db = try AppDatabase.inMemory()
    try learn(db, ["Hide sidebar"])
    let reader = FakeReader(ctx(app: "Claude", bundleID: sidebarApp), "Hide sidebar\nFirst body of the document one")
    let e = CaptureEngine(reader: reader, db: db)
    guard case .stored(let a) = await e.tick() else { Issue.record("a"); return }
    #expect(!(try SnapshotStore(db).snapshots(ids: [a])[0].text.contains("Hide sidebar")))
    try DataReset.deleteAllCapturedData(in: db)  // clears boilerplate and bumps the generation
    reader.setText("Hide sidebar\nSecond body of the document two")
    guard case .stored(let b) = await e.tick() else { Issue.record("b"); return }
    #expect(try SnapshotStore(db).snapshots(ids: [b])[0].text.contains("Hide sidebar"))
    // Refit at 20 docs after the reset.
    for i in 0..<19 {
        reader.setText("Hide sidebar\nDistinct body after reset about topic \(String(repeating: "q", count: i + 1))")
        _ = await e.tick()
    }
    #expect(try BoilerplateStore(db).learned(surface: surface) == [BoilerplateLine.hash("Hide sidebar")])
}

@Test func boilerplateFailureNeverLosesTheSnapshot() async throws {
    let db = try AppDatabase.inMemory()
    try dropStats(db)
    let e = CaptureEngine(reader: FakeReader(ctx(app: "Claude", bundleID: sidebarApp),
                                             "Hide sidebar\nA real document body that must be kept"), db: db)
    guard case .stored(let id) = await e.tick() else { Issue.record("snapshot lost"); return }
    #expect(try SnapshotStore(db).snapshots(ids: [id])[0].text.contains("real document body"))
    #expect(try surfaceDocs(db) == nil)  // the savepoint rolled the surface count back too
}

@Test func firstFitHappensAtTwentiethDoc() async throws {
    let db = try AppDatabase.inMemory()
    let reader = FakeReader(ctx(app: "Claude", bundleID: sidebarApp), "x")
    let e = CaptureEngine(reader: reader, db: db)
    let store = BoilerplateStore(db)
    for i in 0..<20 {
        // A different body each time falls below the continuation threshold: a new row (doc).
        reader.setText("Hide sidebar\nDistinct document body number about topic \(String(repeating: "q", count: i + 1))")
        guard case .stored = await e.tick() else { Issue.record("not stored \(i)"); return }
        if i < 19 { #expect(try store.learned(surface: surface).isEmpty) }
    }
    #expect(try store.learned(surface: surface) == [BoilerplateLine.hash("Hide sidebar")])
    #expect(try store.surfacesNeedingFirstFit().isEmpty)
}

@Test func excludedContextIsNeverSampled() async throws {
    let db = try AppDatabase.inMemory()
    try ExclusionStore(db).add("app:Claude")
    let e = CaptureEngine(reader: FakeReader(ctx(app: "Claude", bundleID: sidebarApp), "Hide sidebar\nPlain text of some length here"), db: db)
    #expect(await e.tick() == .excluded)
    #expect(try surfaceDocs(db) == nil)
}
