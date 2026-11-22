import Foundation
@testable import Storage

extension Snapshot {
    static func fixture(
        text: String,
        app: String = "Notes",
        windowTitle: String? = nil,
        capturedAt: Date = Date(timeIntervalSince1970: 1_000_000)
    ) -> Snapshot {
        Snapshot(
            id: nil, capturedAt: capturedAt, app: app, bundleID: nil,
            windowTitle: windowTitle, url: nil, domain: nil, filePath: nil,
            text: text, contentHash: "hash-\(text.hashValue)", source: .ax)
    }
}

func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "remora-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

extension LLMCall {
    static func fixture(
        model: String = "gpt-6-luna", backend: String = "siwc", job: String = "rewrite",
        status: LLMCallStatus = .completed, input: Int = 10, output: Int = 5,
        cost: Double? = nil, at: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> LLMCall {
        LLMCall(startedAt: at, durationMs: 250, backend: backend, model: model,
                reasoningEffort: "low", jobType: job, status: status, inputTokens: input,
                outputTokens: output, estCostUSD: cost)
    }
}

extension InlineOutput {
    static func fixture(
        mode: InlineMode = .selection, original: String = "orig", result: String = "res",
        llmCallID: Int64? = nil, at: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> InlineOutput {
        InlineOutput(createdAt: at, llmCallID: llmCallID, mode: mode, app: "Notes",
                     surface: "notes", original: original, result: result)
    }
}

// MARK: - Plan 4 memory fixtures

let memoryT0 = Date(timeIntervalSince1970: 1_700_000_000)

extension Chronicle {
    static func fixture(
        level: ChronicleLevel = .day, key: String = "2023-11-14", summary: String = "summary",
        llmCallID: Int64? = nil, at: Date = memoryT0
    ) -> Chronicle {
        Chronicle(level: level, periodKey: key, periodStart: at, periodEnd: at.addingTimeInterval(86_400),
                  summary: summary, generatedAt: at, llmCallID: llmCallID)
    }
}

extension WikiPage {
    static func fixture(slug: String = "ada", title: String = "Ada", body: String = "",
                        llmCallID: Int64? = nil, at: Date = memoryT0) -> WikiPage {
        WikiPage(slug: slug, type: .person, title: title, body: body, firstSeen: at, lastSeen: at,
                 updatedAt: at, llmCallID: llmCallID)
    }
}

extension WikiFact {
    static func fixture(slug: String = "ada", fact: String = "Ada writes code", normKey: String = "ada writes code",
                        llmCallID: Int64? = nil, at: Date = memoryT0) -> WikiFact {
        WikiFact(slug: slug, fact: fact, normKey: normKey, subject: .thirdParty, basis: .onScreenContent,
                 worth: .core, validAt: at, recordedAt: at, lastConfirmedAt: at, llmCallID: llmCallID)
    }
}

extension Job {
    static func fixture(kind: JobKind = .hour, key: String = "2023-11-14T22+0000", at: Date = memoryT0) -> Job {
        Job(kind: kind, periodKey: key, nextRunAt: at, createdAt: at)
    }
}

/// Inserts one row in every v4 table (and returns the llm call they cite).
@discardableResult
func seedMemoryRows(_ db: AppDatabase, marker: String = "memmarker") throws -> LLMCall {
    let call = try LLMCallStore(db).insert(.fixture(job: "hour_chronicle"))
    try db.writer.write { d in
        var job = Job.fixture(); try job.insert(d)
        var wm = WorkingMemoryItem(text: "wm \(marker)", kind: "task", normKey: "wm \(marker)", relevance: 0.9,
                                   snapshotIDs: [1], addedAt: memoryT0, lastSeenAt: memoryT0, llmCallID: call.id)
        try wm.insert(d)
        var ch = Chronicle.fixture(summary: "chronicle \(marker)", llmCallID: call.id); try ch.insert(d)
        var page = WikiPage.fixture(body: "page \(marker)", llmCallID: call.id); try page.insert(d)
        var fact = WikiFact.fixture(fact: "fact \(marker)", llmCallID: call.id); try fact.insert(d)
        var identity = IdentityRevision(body: "identity \(marker)", source: .llm, createdAt: memoryT0,
                                        llmCallID: call.id)
        try identity.insert(d)
        var flag = SalientFlag(kind: .todo, text: "flag \(marker)", owner: .user, dedupeKey: "todo:\(marker)",
                               createdAt: memoryT0, lastSeenAt: memoryT0, llmCallID: call.id)
        try flag.insert(d)
        var row = TimeLedgerRow(hourStart: memoryT0, project: "Remora", app: "Xcode", seconds: 1_800)
        try row.insert(d)
        var vector = EmbeddingRecord(ownerTable: "chronicle", ownerID: ch.id!, modelID: "m", revision: 1, dims: 2,
                                     vector: Data([0, 0, 128, 63, 0, 0, 0, 0]), contentHash: "c",
                                     createdAt: memoryT0)
        try vector.insert(d)
        var digest = MemoryDigest(body: "digest \(marker)", createdAt: memoryT0, llmCallID: call.id)
        try digest.insert(d)
        try d.execute(sql: "INSERT INTO boilerplate (surface, line_hash, line_text, learned_at) VALUES ('app:x', 'h', ?, ?)",
                      arguments: ["Sign in \(marker)", memoryT0])
        try d.execute(sql: "INSERT INTO boilerplate_stats (surface, line_hash, line_text, docs) VALUES ('app:x', 'h', ?, 3)",
                      arguments: ["Sign in \(marker)"])
        try d.execute(sql: "INSERT INTO boilerplate_surfaces (surface, docs, fitted_at) VALUES ('app:x', 25, ?)",
                      arguments: [memoryT0])
        try d.execute(sql: "INSERT INTO snapshot_sources (id, app, bundle_id, domain, url_host) VALUES (1, 'Notes', NULL, NULL, NULL)")
    }
    return call
}

/// Every v4 table that delete-all empties.
let derivedMemoryTables = [
    "working_memory", "chronicle", "wiki_facts", "wiki_pages", "identity", "salient_flags", "time_ledger",
    "jobs", "embeddings", "boilerplate", "boilerplate_stats", "boilerplate_surfaces", "memory_digest",
    "snapshot_sources",
]
