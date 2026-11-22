import Foundation
import GRDB
import LLM
import LLMTestSupport
import Memory
import Synchronization
@testable import Assistant
import Storage

// Shared fixtures for the proactive tests (Task 6). Friday 2026-11-20, Europe/Paris.

let proactiveCatalog = [ModelInfo(slug: "gpt-6-luna", displayName: "Luna"),
                        ModelInfo(slug: "gpt-6.1-terra", displayName: "Terra")]

/// `"2026-11-20 10:30"` in Paris.
func local(_ s: String) -> Date {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "Europe/Paris")
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.date(from: s)!
}

/// A settable clock shared by a runner and a fake model.
final class LiveClock: Sendable {
    private let t: Mutex<Date>
    init(_ d: Date) { t = Mutex(d) }
    func now() -> Date { t.withLock { $0 } }
    func set(_ d: Date) { t.withLock { $0 = d } }
}

/// Thread-safe FIFO of canned answers.
final class Replies: Sendable {
    private let items: Mutex<[String]>
    init(_ items: [String]) { self.items = Mutex(items) }
    func next() -> String { items.withLock { $0.isEmpty ? "" : $0.removeFirst() } }
}

let checkOK = #"{"supported":true,"unsupported":[]}"#
func checkBad(_ claims: [String]) -> String {
    let list = claims.map { "\"\($0)\"" }.joined(separator: ",")
    return #"{"supported":false,"unsupported":["# + list + "]}"
}

func isCheck(_ r: LLMRequest) -> Bool {
    if case .jsonSchema(let name, _, _) = r.format { return name == "proactive_check" }
    return false
}

/// Drafts come from `drafts`, checks from `checks`; `onRequest` runs first (to move a clock, wipe
/// data…).
func writerFake(drafts: [String], checks: [String],
                onRequest: @escaping @Sendable (LLMRequest) -> Void = { _ in }) -> FakeLLMClient {
    let d = Replies(drafts), c = Replies(checks)
    return FakeLLMClient(backend: .siwc) { request in
        onRequest(request)
        let text = isCheck(request) ? c.next() : d.next()
        return [.delta(text), .complete(.init(inputTokens: 100, cachedInputTokens: 0, outputTokens: 20, reasoningTokens: 0))]
    }
}

func service(_ fake: FakeLLMClient, db: AppDatabase) -> LLMService {
    LLMService(siwc: fake, onDevice: FakeLLMClient(backend: .onDevice, script: []),
               onDeviceAvailability: { .available }, calls: LLMCallStore(db),
               routing: { RoutingConfig() }, catalog: { proactiveCatalog }, prices: { .empty },
               retryDelay: .zero)
}

func jobContext(_ now: Date, generation: Int = 0, cloud: Bool = true) -> JobContext {
    JobContext(now: now, calendar: paris, generation: generation, cloudAllowed: cloud, language: .en)
}

/// Every user input item of `r`, joined.
func inputText(_ r: LLMRequest) -> String {
    r.input.map { item -> String in
        if case .user(let s) = item { return s }
        return ""
    }.joined(separator: "\n")
}

func jobTypes(_ db: AppDatabase) throws -> [String] {
    try db.reader.read { d in try String.fetchAll(d, sql: "SELECT job_type FROM llm_calls ORDER BY id") }
}

// MARK: - Seeding

@discardableResult
func seedSnapshot(_ db: AppDatabase, at: Date, app: String = "Notes", text: String = "notes") throws -> Snapshot {
    try SnapshotStore(db).insert(Snapshot(capturedAt: at, app: app, text: text,
                                          contentHash: "h-\(at.timeIntervalSince1970)-\(app)", source: .ax))
}

@discardableResult
func seedChronicle(_ db: AppDatabase, _ level: ChronicleLevel, start: Date, summary: String,
                   snapshotIDs: [Int64]) throws -> Chronicle {
    let period = PeriodKey.interval(level, containing: start, calendar: paris)
    let c = Chronicle(level: level, periodKey: PeriodKey.key(level, for: start, calendar: paris),
                      periodStart: period.start, periodEnd: period.end, summary: summary,
                      snapshotIDs: snapshotIDs, generatedAt: period.end)
    return try db.writer.write { d in try ChronicleStore(db).upsert(c, in: d) }
}

@discardableResult
func seedFlag(_ db: AppDatabase, _ kind: FlagKind, _ text: String, owner: FlagOwner = .user, due: Date? = nil,
              status: FlagStatus = .open, seen: Date, closedAt: Date? = nil, snapshotIDs: [Int64]) throws -> SalientFlag {
    var f = SalientFlag(kind: kind, text: text, owner: owner, dueAt: due, status: status,
                        snapshotIDs: snapshotIDs,
                        dedupeKey: SalientFlagStore.dedupeKey(kind: kind, text: text, person: ""),
                        createdAt: seen, lastSeenAt: seen, closedAt: closedAt)
    try db.writer.write { d in try f.insert(d) }
    return f
}

@discardableResult
func seedWorkingMemory(_ db: AppDatabase, _ text: String, seen: Date, snapshotIDs: [Int64]) throws -> WorkingMemoryItem {
    var i = WorkingMemoryItem(text: text, kind: "task", normKey: text.lowercased(), relevance: 1,
                              snapshotIDs: snapshotIDs, addedAt: seen, lastSeenAt: seen)
    try db.writer.write { d in try i.insert(d) }
    return i
}

func inboxRows(_ db: AppDatabase) throws -> [InboxMessage] {
    try db.reader.read { d in try InboxMessage.fetchAll(d, sql: "SELECT * FROM inbox_messages ORDER BY id") }
}

func chatRows(_ db: AppDatabase) throws -> [ChatTurn] {
    try db.reader.read { d in try ChatTurn.fetchAll(d, sql: "SELECT * FROM chat_turns ORDER BY id") }
}

/// Counts `onDelivered` calls.
final class DeliveryLog: Sendable {
    private let items = Mutex<[InboxMessage]>([])
    func record(_ m: InboxMessage) { items.withLock { $0.append(m) } }
    var all: [InboxMessage] { items.withLock { $0 } }
}

func makeInbox(_ db: AppDatabase, _ log: DeliveryLog = DeliveryLog()) -> ProactiveInbox {
    ProactiveInbox(db: db, onDelivered: { log.record($0) })
}
