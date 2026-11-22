import Capture
import Embeddings
import Foundation
import GRDB
import Storage
@testable import Retrieval

/// Shared seeding helpers for the memory retrieval tests (Task 12).
let memNow = Date(timeIntervalSince1970: 1_800_000_000)

@discardableResult
func seedSnapshot(_ db: AppDatabase, _ text: String, app: String = "Slack", bundleID: String? = nil,
                  title: String? = "General", domain: String? = nil, url: String? = nil,
                  ago: TimeInterval = 60) throws -> Snapshot {
    try SnapshotStore(db).insert(Snapshot(capturedAt: memNow.addingTimeInterval(-ago), app: app, bundleID: bundleID,
                                          windowTitle: title, url: url, domain: domain, text: text,
                                          contentHash: UUID().uuidString, source: .ax))
}

@discardableResult
func seedChronicle(_ db: AppDatabase, key: String, summary: String, level: ChronicleLevel = .hour,
                   start: Date = memNow.addingTimeInterval(-7_200), snapshotIDs: [Int64] = []) throws -> Chronicle {
    try db.writer.write { d in
        try ChronicleStore(db).upsert(Chronicle(level: level, periodKey: key, periodStart: start,
                                                periodEnd: start.addingTimeInterval(3_600), summary: summary,
                                                snapshotIDs: snapshotIDs, generatedAt: start), in: d)
    }
}

@discardableResult
func seedPage(_ db: AppDatabase, slug: String, title: String, type: WikiPageType = .project, summary: String = "",
              body: String = "", lastSeen: Date = memNow.addingTimeInterval(-3_600),
              snapshotIDs: [Int64] = []) throws -> WikiPage {
    try db.writer.write { d in
        try WikiStore.insert(WikiPage(slug: slug, type: type, title: title, summary: summary, body: body,
                                      mentionCount: 3, firstSeen: lastSeen, lastSeen: lastSeen,
                                      snapshotIDs: snapshotIDs, updatedAt: lastSeen), in: d)
    }
}

@discardableResult
func seedFact(_ db: AppDatabase, slug: String, _ text: String, invalid: Bool = false,
              snapshotIDs: [Int64] = []) throws -> WikiFact {
    try db.writer.write { d in
        try WikiStore.insert(WikiFact(slug: slug, fact: text, normKey: TextFold.key(text), subject: .world,
                                      basis: .onScreenContent, worth: .detail, snapshotIDs: snapshotIDs,
                                      validAt: memNow.addingTimeInterval(-86_400),
                                      invalidAt: invalid ? memNow.addingTimeInterval(-3_600) : nil,
                                      recordedAt: memNow.addingTimeInterval(-86_400),
                                      lastConfirmedAt: memNow.addingTimeInterval(-3_600)), in: d)
    }
}

@discardableResult
func seedFlag(_ db: AppDatabase, _ kind: FlagKind, _ text: String, person: String = "", project: String = "",
              due: Date? = nil, snapshotIDs: [Int64] = []) throws -> SalientFlag {
    try db.writer.write { d in
        try SalientFlagStore.upsert(SalientFlag(kind: kind, text: text, owner: .user, person: person, project: project,
                                                dueAt: due, snapshotIDs: snapshotIDs,
                                                dedupeKey: SalientFlagStore.dedupeKey(kind: kind, text: text, person: person),
                                                createdAt: memNow.addingTimeInterval(-86_400),
                                                lastSeenAt: memNow.addingTimeInterval(-3_600)), in: d)
    }
}

func seedWorkingMemory(_ db: AppDatabase, _ items: [(String, [Int64])]) throws {
    let rows = items.enumerated().map { i, item in
        WorkingMemoryItem(text: item.0, kind: "topic", normKey: "", relevance: 0.9 - Double(i) / 100,
                          snapshotIDs: item.1, addedAt: memNow, lastSeenAt: memNow)
    }
    try db.writer.write { d in try WorkingMemoryStore(db).merge(rows, now: memNow, in: d) }
}

func seedDigest(_ db: AppDatabase, _ body: String) throws {
    try db.writer.write { d in _ = try MemoryDigestStore(db).insert(MemoryDigest(body: body, createdAt: memNow), in: d) }
}

/// Indexes every chronicle, page and valid fact with `embedder`.
func indexAll(_ db: AppDatabase, _ embedder: any Embedder) async throws {
    _ = try await EmbeddingIndexer(db: db, embedder: embedder).run(limit: 1_000, at: memNow,
                                                                    generation: try DataGeneration.current(db))
}

/// An embedder whose model is unavailable.
struct UnavailableEmbedder: Embedder {
    func identity() async -> EmbedderIdentity? { nil }
    func embed(_ text: String) async throws -> [Float] { throw EmbeddingError.unavailable }
}

/// Records every expansion and adds fixed synonyms.
final class RecordingExpander: QueryExpander, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [(terms: [String], cloudAllowed: Bool)] = []
    private let added: [String: [String]]
    private let hang: Bool

    init(added: [String: [String]] = [:], hang: Bool = false) { self.added = added; self.hang = hang }

    var calls: [(terms: [String], cloudAllowed: Bool)] { lock.withLock { log } }

    func expand(_ terms: [String], cloudAllowed: Bool, timeout: Duration) async -> [String] {
        lock.withLock { log.append((terms, cloudAllowed)) }
        if hang {
            // Ignores cancellation and the timeout: the assembler's own bound must still return.
            await Task.detached { try? await Task.sleep(for: .seconds(3_600)) }.value
        }
        return terms + terms.flatMap { added[$0] ?? [] }
    }
}

func openPolicy() -> CapturePolicy { CapturePolicy(userRules: []) }

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}
