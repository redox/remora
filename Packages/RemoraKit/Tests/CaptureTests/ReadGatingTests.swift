import Foundation
import Storage
import Testing
@testable import Capture

/// Mimics `FrontmostWindowReader`: the tree is walked (text extracted) only when the policy
/// it is given allows the context. Counts walks.
final class WalkCountingReader: WindowReading {
    let context: WindowContext
    private let walks = Mutex2<Int>(0)
    var walkCount: Int { walks.get() }
    init(_ context: WindowContext) { self.context = context }

    func readFrontmost() async throws -> (context: WindowContext, text: String)? {
        try await readFrontmost(policy: CapturePolicy(userRules: []))
    }

    func readFrontmost(policy: CapturePolicy) async throws -> (context: WindowContext, text: String)? {
        guard policy.shouldCapture(context) else { return (context, "") }
        walks.set(walks.get() + 1)
        return (context, "Quarterly planning notes for the Oslo trip itinerary")
    }
}

// MARK: - User exclusions are applied before the AX walk (final review #4)

@Test func userExcludedAppIsNeverWalked() async throws {
    let db = try AppDatabase.inMemory()
    try ExclusionStore(db).add("app:Notes")
    let reader = WalkCountingReader(ctx(app: "Notes", title: "Diary"))
    let e = CaptureEngine(reader: reader, db: db)
    #expect(await e.tick() == .excluded)
    #expect(reader.walkCount == 0)
}

@Test func userExcludedTitleAndDomainAreNeverWalked() async throws {
    let db = try AppDatabase.inMemory()
    try ExclusionStore(db).add("title:payroll")
    try ExclusionStore(db).add("intranet.example.com")
    let byTitle = WalkCountingReader(ctx(app: "Numbers", title: "Payroll 2026"))
    #expect(await CaptureEngine(reader: byTitle, db: db).tick() == .excluded)
    #expect(byTitle.walkCount == 0)
    let byDomain = WalkCountingReader(ctx(app: "Safari", url: "https://hr.intranet.example.com/x"))
    #expect(await CaptureEngine(reader: byDomain, db: db).tick() == .excluded)
    #expect(byDomain.walkCount == 0)
}

@Test func unreadableExclusionsMeanNoWalk() async throws {
    let db = try AppDatabase.inMemory()
    try await db.writer.write { try $0.execute(sql: "DROP TABLE exclusions") }
    let reader = WalkCountingReader(ctx(app: "Notes", title: "T"))
    #expect(await CaptureEngine(reader: reader, db: db).tick() == .excluded)
    #expect(reader.walkCount == 0)
    // Focus is still recorded, app-only.
    let ev = try ActivityStore(db).events(since: .distantPast)
    #expect(ev.count == 1 && ev[0].windowTitle == nil)
}

@Test func allowedAppIsWalkedOnce() async throws {
    let db = try AppDatabase.inMemory()
    let reader = WalkCountingReader(ctx(app: "Notes", title: "Diary"))
    guard case .stored = await CaptureEngine(reader: reader, db: db).tick() else {
        Issue.record("not stored"); return
    }
    #expect(reader.walkCount == 1)
}

@Test func denyAllPolicyCapturesNothing() {
    #expect(!CapturePolicy.denyAll.shouldCapture(ctx(app: "Notes")))
}

// MARK: - Pause: the pasteboard is not read (final review #4)

final class CountingPasteboard: PasteboardReading, @unchecked Sendable {
    private let lock = NSLock()
    private var _changeCount: Int
    private var _string: String
    private(set) var contentReads = 0
    init(changeCount: Int, string: String) { _changeCount = changeCount; _string = string }
    var changeCount: Int { lock.withLock { _changeCount } }
    func string() -> String? { lock.withLock { contentReads += 1; return _string } }
    func types() -> [String] { lock.withLock { contentReads += 1; return ["public.utf8-plain-text"] } }
    func copy(_ s: String) { lock.withLock { _changeCount += 1; _string = s } }
    var reads: Int { lock.withLock { contentReads } }
}

@Test func consumeWithoutReadingNeverTouchesContentAndSkipsPausedCopies() {
    let pb = CountingPasteboard(changeCount: 1, string: "before")
    let w = ClipboardWatcher(pasteboard: pb, onText: { _ in })
    pb.copy("copied while paused")
    w.consumeWithoutReading()  // paused poll
    #expect(pb.reads == 0)
    // After resume, the copy made during the pause is not reported.
    #expect(w.poll() == nil)
    #expect(pb.reads == 0)
    pb.copy("after resume")
    #expect(w.poll() == "after resume")
}

// MARK: - Clipboard size cap (final review #5)

@Test func clipboardTextCappedBeforeRedaction() async throws {
    let db = try AppDatabase.inMemory()
    let e = CaptureEngine(reader: FakeReader(ctx(app: "Notes"), "x"), db: db)
    let big = String(repeating: "abcdefghij ", count: 10_000)  // 110,000 chars
    guard case .stored(let id) = await e.storeClipboard(text: big, context: ctx(app: "Notes", title: "Doc")) else {
        Issue.record("not stored"); return
    }
    let s = try SnapshotStore(db).snapshots(ids: [id])[0]
    #expect(s.text.count == CaptureEngine.clipboardCharLimit)
    #expect(CaptureEngine.clipboardCharLimit == 50_000)
}
