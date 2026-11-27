import Embeddings
import Foundation
import GRDB
import MCP
import Storage
import Testing
@testable import MCPServer

private func tempDBURL() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "remora-mcp-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    return dir.appending(path: "remora.sqlite")
}

private func snap(_ text: String, app: String = "Notes", at t: TimeInterval = 1_000_000,
                  title: String? = nil) -> Snapshot {
    Snapshot(capturedAt: Date(timeIntervalSince1970: t), app: app, windowTitle: title,
             text: text, contentHash: UUID().uuidString, source: .ax)
}

/// Creates a DB, inserts the snapshots, and fully closes the read-write connection.
private func seededDB(snapshots: [Snapshot]) throws -> URL {
    let url = tempDBURL()
    let db = try AppDatabase.open(at: url)
    let store = SnapshotStore(db)
    for s in snapshots { _ = try store.insert(s) }
    return url
}

private func seededDB(texts: [String]) throws -> URL {
    try seededDB(snapshots: texts.map { snap($0) })
}

private func decode(_ text: String) throws -> Any {
    try JSONSerialization.jsonObject(with: Data(text.utf8))
}

@Test func listsTwelveReadOnlyTools() {
    #expect(MemoryTools.definitions.count == 12)
    #expect(Set(MemoryTools.definitions.map(\.name))
        == ["search_recorded_meetings", "search_memory", "get_snapshots", "read_session", "get_recent_activity", "get_usage",
            "get_chronicle", "get_working_memory", "get_attention_context", "search_wiki", "get_wiki_page", "list_wiki"])
}

private func seededUsageDB() throws -> URL {
    let url = tempDBURL()
    let db = try AppDatabase.open(at: url)
    let calls = LLMCallStore(db)
    func call(_ job: String, model: String, at t: TimeInterval, cost: Double?, status: LLMCallStatus = .completed) throws {
        _ = try calls.insert(LLMCall(startedAt: Date(timeIntervalSince1970: t), durationMs: 5, backend: "siwc", model: model,
                                     jobType: job, status: status, inputTokens: 100, cachedInputTokens: 10,
                                     outputTokens: 20, reasoningTokens: 5, estCostUSD: cost))
    }
    try call("rewrite", model: "gpt-6-luna", at: 2_000_000, cost: 0.5)
    try call("rewrite", model: "gpt-6-luna", at: 2_000_100, cost: nil)
    try call("chat", model: "gpt-6.1-terra", at: 2_000_200, cost: nil)
    try call("rewrite", model: "gpt-6-luna", at: 1_000, cost: 9)  // before `since`
    return url
}

@Test func usageTotalsAsJSON() async throws {
    let url = try seededUsageDB()
    let r = await MemoryTools(databaseURL: url).call("get_usage", arguments: ["since": 1_900_000, "group_by": "job_type"])
    #expect(!r.isError)
    #expect(r.text.contains("\"key\":\"rewrite\""))
    #expect(r.text.contains("est_cost_usd") && r.text.contains("API-equivalent"))
    let o = try #require(try decode(r.text) as? [String: Any])
    let totals = try #require(o["totals"] as? [[String: Any]])
    let rewrite = try #require(totals.first { $0["key"] as? String == "rewrite" })
    #expect(rewrite["calls"] as? Int == 2)
    #expect(rewrite["unpriced_calls"] as? Int == 1)
    #expect(rewrite["cached_input_tokens"] as? Int == 20)
    let chat = try #require(totals.first { $0["key"] as? String == "chat" })
    #expect(chat["est_cost_usd"] is NSNull)
}

@Test func usageGroupsByModelAndRejectsBadGrouping() async throws {
    let tools = MemoryTools(databaseURL: try seededUsageDB())
    let m = await tools.call("get_usage", arguments: ["since": 1_900_000, "group_by": "model"])
    #expect(m.text.contains("\"key\":\"gpt-6.1-terra\""))
    let bad = await tools.call("get_usage", arguments: ["group_by": "color"])
    #expect(bad.isError && bad.text.contains("group_by"))
}

@Test func usageDefaultsToDayAndSevenDays() async throws {
    // Default window is the last 7 days: the 1970s fixture rows fall outside it.
    let r = await MemoryTools(databaseURL: try seededUsageDB()).call("get_usage", arguments: [:])
    #expect(!r.isError)
    let o = try #require(try decode(r.text) as? [String: Any])
    #expect((o["totals"] as? [Any])?.isEmpty == true)
}

@Test func usageOnPreV3DatabaseIsFriendlyError() async throws {
    let url = tempDBURL()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let q = try DatabaseQueue(path: url.path)
    try await q.write { try $0.execute(sql: "CREATE TABLE snapshots (id INTEGER PRIMARY KEY)") }
    let r = await MemoryTools(databaseURL: url).call("get_usage", arguments: [:])
    #expect(r.isError && r.text.contains("Remora"))
    #expect(!r.text.contains("SQLite"))
}

@Test func searchReturnsHitsAsJSON() async throws {
    let url = try seededDB(texts: ["Réunion pricing avec Oslo team"])
    let r = await MemoryTools(databaseURL: url).call("search_memory", arguments: ["query": "reunion pricing"])
    #expect(!r.isError && r.text.contains("\"app\"") && r.text.contains("pricing"))
    let rows = try #require(try decode(r.text) as? [[String: Any]])
    #expect(rows.count == 1)
    #expect(rows[0]["captured_at"] as? Int == 1_000_000)
}

@Test func recallInstructionsAskClientsToCiteDecisionsAndDiscloseGaps() {
    let instructions = MemoryTools.serverInstructions.lowercased()
    for term in ["cite", "snapshot id", "decision", "proposal", "conflict", "could not verify"] {
        #expect(instructions.contains(term), "Missing recall guidance: \(term)")
    }
}

@Test func limitsAreClamped() async throws {
    let url = try seededDB(snapshots: (0..<30).map { snap("budget item \($0)", at: 1_000_000 + Double($0)) })
    let tools = MemoryTools(databaseURL: url)
    let r = await tools.call("search_memory", arguments: ["query": "budget", "limit": 100])
    #expect(try #require(try decode(r.text) as? [Any]).count == 20)
    let d = await tools.call("search_memory", arguments: ["query": "budget"])
    #expect(try #require(try decode(d.text) as? [Any]).count == 10)
    let z = await tools.call("search_memory", arguments: ["query": "budget", "limit": 0])
    #expect(try #require(try decode(z.text) as? [Any]).count == 1)
}

@Test func searchFiltersByAppAndTime() async throws {
    let url = try seededDB(snapshots: [
        snap("alpha plan", app: "Notes", at: 100), snap("alpha plan", app: "Safari", at: 200),
        snap("alpha plan", app: "Safari", at: 300),
    ])
    let r = await MemoryTools(databaseURL: url).call(
        "search_memory", arguments: ["query": "alpha", "app": "Safari", "since": 250, "until": 400])
    #expect(try #require(try decode(r.text) as? [Any]).count == 1)
}

@Test func getSnapshotsTruncatesHugeText() async throws {
    let url = try seededDB(texts: [String(repeating: "x", count: 30_000)])
    let r = await MemoryTools(databaseURL: url).call("get_snapshots", arguments: ["ids": [1]])
    #expect(!r.isError)
    let rows = try #require(try decode(r.text) as? [[String: Any]])
    #expect((rows[0]["text"] as? String)?.count == 20_000)
    #expect(rows[0]["truncated"] as? Bool == true)
}

@Test func getSnapshotsReturnsFullShortText() async throws {
    let url = try seededDB(texts: ["short text"])
    let r = await MemoryTools(databaseURL: url).call("get_snapshots", arguments: ["ids": [1]])
    let rows = try #require(try decode(r.text) as? [[String: Any]])
    #expect(rows[0]["text"] as? String == "short text")
    #expect(rows[0]["truncated"] == nil)
}

@Test func readSessionReturnsOrderedCappedText() async throws {
    let url = try seededDB(snapshots: [
        snap(String(repeating: "y", count: 5_000), app: "Xcode", at: 200),
        snap("first", app: "Xcode", at: 100), snap("other app", app: "Safari", at: 150),
    ])
    let r = await MemoryTools(databaseURL: url).call(
        "read_session", arguments: ["app": "Xcode", "start": 0, "end": 1000])
    let rows = try #require(try decode(r.text) as? [[String: Any]])
    #expect(rows.count == 2)
    #expect(rows[0]["text"] as? String == "first")
    #expect((rows[1]["text"] as? String)?.count == 2_000)
}

@Test func recentActivityReturnsSnapshotsAndEvents() async throws {
    let url = tempDBURL()
    do {
        let db = try AppDatabase.open(at: url)
        _ = try SnapshotStore(db).insert(snap("recent thing", at: Date().timeIntervalSince1970))
        try ActivityStore(db).recordFocus(app: "Safari", bundleID: nil, windowTitle: "Docs",
                                          domain: "example.com", at: Date())
        try await db.writer.write { d in
            var old = ActivityEvent(app: "Old", startedAt: Date(timeIntervalSinceNow: -5 * 3600),
                                    endedAt: Date(timeIntervalSinceNow: -4 * 3600))
            try old.insert(d)
        }
    }
    let r = await MemoryTools(databaseURL: url).call("get_recent_activity", arguments: [:])
    #expect(!r.isError)
    let obj = try #require(try decode(r.text) as? [String: Any])
    #expect((obj["snapshots"] as? [Any])?.count == 1)
    let events = try #require(obj["activity"] as? [[String: Any]])
    #expect(events.contains { $0["app"] as? String == "Safari" && $0["started_at"] is Int })
    #expect(!events.contains { $0["app"] as? String == "Old" })
}

@Test func missingDatabaseReturnsFriendlyError() async {
    let r = await MemoryTools(databaseURL: URL(filePath: "/nonexistent/remora.sqlite"))
        .call("search_memory", arguments: ["query": "x"])
    #expect(r.isError && r.text.contains("Remora"))
}

@Test func badArgumentsAreToolErrors() async throws {
    let tools = MemoryTools(databaseURL: try seededDB(texts: ["hello"]))
    let tooMany: [String: Value] = ["ids": .array((1...11).map { Value.int($0) })]
    let cases: [(String, [String: Value])] = [
        ("search_memory", [:]), ("search_memory", ["query": 5]), ("get_snapshots", ["ids": "abc"]),
        ("get_snapshots", tooMany), ("read_session", ["app": "X"]), ("nope", [:]),
    ]
    for (name, args) in cases {
        let r = await tools.call(name, arguments: args)
        #expect(r.isError, "\(name) \(args)")
    }
}

// MARK: - Carried risk from Task 3: read-only access to a WAL database

@Test func readsWhileAppHasOpenWriterAndPendingWrite() async throws {
    let url = tempDBURL()
    let app = try AppDatabase.open(at: url)
    _ = try SnapshotStore(app).insert(snap("committed before"))
    try await app.writer.write { d in
        var pending = snap("uncommitted pending")
        try pending.insert(d)
        // A second connection (the MCP process) reads while this write transaction is open.
        let reader = try AppDatabase.openReadOnly(at: url)
        #expect(try SnapshotStore(reader).search("committed").count == 1)
        #expect(try SnapshotStore(reader).search("uncommitted").isEmpty)
    }
    let r = await MemoryTools(databaseURL: url).call("search_memory", arguments: ["query": "uncommitted"])
    #expect(!r.isError && r.text.contains("uncommitted"))
}

private func copyDB(_ url: URL, to dest: URL, including suffixes: [String]) throws {
    try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
    for suffix in suffixes {
        try? FileManager.default.copyItem(atPath: url.path + suffix, toPath: dest.path + suffix)
    }
}

private func exists(_ url: URL, _ suffix: String) -> Bool {
    FileManager.default.fileExists(atPath: url.path + suffix)
}

/// Writer stays open so committed frames live in -wal; returns a crash-like copy.
private func crashCopy(keepShm: Bool) async throws -> (app: AppDatabase, copy: URL) {
    let url = tempDBURL()
    let app = try AppDatabase.open(at: url)
    _ = try SnapshotStore(app).insert(snap("older row"))
    _ = try SnapshotStore(app).insert(snap("newest committed row"))
    let copy = tempDBURL()
    try copyDB(url, to: copy, including: ["", "-wal"] + (keepShm ? ["-shm"] : []))
    return (app, copy)
}

@Test func readsWalCopyWithShmPresent() async throws {
    let (app, copy) = try await crashCopy(keepShm: true)
    withExtendedLifetime(app) {}
    #expect(exists(copy, "-wal") && exists(copy, "-shm"))
    let r = await MemoryTools(databaseURL: copy).call("search_memory", arguments: ["query": "newest"])
    #expect(!r.isError && r.text.contains("newest"))
}

@Test func committedWalWithoutShmNeverSilentlyDropsNewestRow() async throws {
    let (app, copy) = try await crashCopy(keepShm: false)
    withExtendedLifetime(app) {}
    #expect(exists(copy, "-wal") && !exists(copy, "-shm"))
    let walSize = try FileManager.default.attributesOfItem(atPath: copy.path + "-wal")[.size] as? Int ?? 0
    #expect(walSize > 0)
    let r = await MemoryTools(databaseURL: copy).call("search_memory", arguments: ["query": "newest"])
    // Either it reads the newest row, or it reports an error; it must never succeed without it.
    #expect(r.isError || r.text.contains("newest"))
}

private func cleanCloseRead(dir: String) async throws {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "remora-mcp-tests-\(UUID().uuidString)/\(dir)", directoryHint: .isDirectory)
        .appending(path: "remora.sqlite")
    do {
        let db = try AppDatabase.open(at: url)
        _ = try SnapshotStore(db).insert(snap("after the app quit"))
        try await db.writer.writeWithoutTransaction { d in try d.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
    }
    try? FileManager.default.removeItem(atPath: url.path + "-wal")
    try? FileManager.default.removeItem(atPath: url.path + "-shm")
    #expect(!exists(url, "-wal") && !exists(url, "-shm"))
    let r = await MemoryTools(databaseURL: url).call("search_memory", arguments: ["query": "quit"])
    #expect(!r.isError && r.text.contains("quit"))
    #expect(!exists(url, "-wal") && !exists(url, "-shm"), "read must not create side files")
}

@Test func readsAfterAppClosedCleanlyWithNoWalOrShm() async throws {
    try await cleanCloseRead(dir: "plain")
}

@Test func fallbackWorksInDirectoryWithSpace() async throws {
    try await cleanCloseRead(dir: "Application Support")
}

@Test func readOnlyOpenerCannotWrite() async throws {
    let url = try seededDB(texts: ["x"])
    let ro = try AppDatabase.openReadOnly(at: url)
    #expect(throws: (any Error).self) {
        try ro.writer.writeWithoutTransaction { d in try d.execute(sql: "DELETE FROM snapshots") }
    }
}

// MARK: - Untrusted-data framing (final review #10)

@Test func instructionsAndEveryToolFrameResultsAsUntrustedData() {
    for text in [MemoryTools.serverInstructions] + MemoryTools.definitions.map(\.description) {
        let t = text.lowercased()
        #expect(t.contains("untrusted"), "\(text)")
        #expect(t.contains("screen") || t.contains("participants"), "\(text)")
        #expect(t.contains("never as instructions"), "\(text)")
    }
}

@Test func appFiltersAreCaseInsensitive() async throws {
    let url = try seededDB(snapshots: [snap("pricing review with Oslo", app: "Notes", at: 100),
                                       snap("pricing review in Slack", app: "Slack", at: 200)])
    let tools = MemoryTools(databaseURL: url)
    let s = await tools.call("search_memory", arguments: ["query": "pricing", "app": "notes"])
    let hits = try #require(try decode(s.text) as? [[String: Any]])
    #expect(hits.count == 1 && hits[0]["app"] as? String == "Notes")
    let r = await tools.call("read_session", arguments: ["app": "NOTES", "start": 0, "end": 1000])
    let rows = try #require(try decode(r.text) as? [[String: Any]])
    #expect(rows.count == 1 && rows[0]["app"] as? String == "Notes")
}

// MARK: - F-43: the current exclusions filter every snapshot-returning tool

/// One allowed snapshot (id 1, Notes) and two captured before the user excluded them: an app
/// (id 2, Vault) and a site (id 3, Safari on hush.example). Focus events for all three.
private func excludedAfterCaptureDB() async throws -> (url: URL, db: AppDatabase) {
    let url = tempDBURL()
    let db = try AppDatabase.open(at: url)
    let now = Date().timeIntervalSince1970
    let store = SnapshotStore(db)
    _ = try store.insert(snap("pricing plan visible", app: "Notes", at: now - 90, title: "Plan"))
    _ = try store.insert(snap("pricing plan zebracode", app: "Vault", at: now - 60, title: "zebracode"))
    _ = try store.insert(Snapshot(capturedAt: Date(timeIntervalSince1970: now - 30), app: "Safari",
                                  bundleID: "com.apple.Safari", windowTitle: "zebracode page",
                                  url: "https://hush.example/x", domain: "hush.example",
                                  text: "pricing plan zebracode site", contentHash: "h3", source: .ax))
    try await db.writer.write { d in
        for (app, bundle, title, domain) in [("Notes", nil, "Plan", nil), ("Vault", nil, "zebracode", nil),
                                             ("Safari", "com.apple.Safari", "zebracode page", "hush.example")] {
            var e = ActivityEvent(app: app, bundleID: bundle, windowTitle: title, domain: domain,
                                  startedAt: Date(timeIntervalSinceNow: -120), endedAt: Date(timeIntervalSinceNow: -10))
            try e.insert(d)
        }
    }
    try ExclusionStore(db).add("app:Vault")
    try ExclusionStore(db).add("hush.example")
    return (url, db)
}

@Test func snapshotToolsDropAppsAndSitesExcludedAfterCapture() async throws {
    let (url, db) = try await excludedAfterCaptureDB()
    withExtendedLifetime(db) {}
    let tools = MemoryTools(databaseURL: url)
    let search = await tools.call("search_memory", arguments: ["query": "pricing"])
    let hits = try #require(try decode(search.text) as? [[String: Any]])
    #expect(hits.map { $0["id"] as? Int } == [1])
    let full = await tools.call("get_snapshots", arguments: ["ids": [1, 2, 3]])
    #expect(try #require(try decode(full.text) as? [[String: Any]]).map { $0["id"] as? Int } == [1])
    let vault = await tools.call("read_session", arguments: ["app": "Vault", "start": 0, "end": 4_000_000_000])
    #expect(try #require(try decode(vault.text) as? [Any]).isEmpty)
    let safari = await tools.call("read_session", arguments: ["app": "Safari", "start": 0, "end": 4_000_000_000])
    #expect(try #require(try decode(safari.text) as? [Any]).isEmpty)
    let recent = await tools.call("get_recent_activity", arguments: [:])
    let obj = try #require(try decode(recent.text) as? [String: Any])
    #expect((obj["snapshots"] as? [[String: Any]])?.map { $0["id"] as? Int } == [1])
    #expect((obj["activity"] as? [[String: Any]])?.map { $0["app"] as? String } == ["Notes"])
    for r in [search, full, vault, safari, recent] {
        #expect(!r.isError)
        #expect(!r.text.contains("Vault") && !r.text.contains("zebracode") && !r.text.contains("hush"))
    }
}

@Test func excludedRowsDoNotStarveTheLimit() async throws {
    let url = tempDBURL()
    let db = try AppDatabase.open(at: url)
    let store = SnapshotStore(db)
    for i in 0..<60 { _ = try store.insert(snap("budget hidden \(i)", app: "Vault", at: 2_000 + Double(i))) }
    for i in 0..<3 { _ = try store.insert(snap("budget shown \(i)", app: "Notes", at: 1_000 + Double(i))) }
    try ExclusionStore(db).add("app:Vault")
    let r = await MemoryTools(databaseURL: url).call("search_memory", arguments: ["query": "budget", "limit": 3])
    let rows = try #require(try decode(r.text) as? [[String: Any]])
    #expect(rows.count == 3 && rows.allSatisfy { $0["app"] as? String == "Notes" })
}

@Test func unreadableExclusionsFailClosed() async throws {
    let url = try seededDB(texts: ["pricing plan visible"])
    let db = try AppDatabase.open(at: url)
    try await db.writer.write { try $0.execute(sql: "DROP TABLE exclusions") }
    let tools = MemoryTools(databaseURL: url)
    for (name, args) in [("search_memory", ["query": Value.string("pricing")]), ("get_snapshots", ["ids": [1]]),
                         ("read_session", ["app": "Notes", "start": 0, "end": 4_000_000_000])] {
        let r = await tools.call(name, arguments: args)
        #expect(!r.isError, "\(name)")
        #expect(try #require(try decode(r.text) as? [Any]).isEmpty, "\(name)")
    }
}

// MARK: - Plan 5 Task 3: the chat shares the app's embedder

/// Every text lands in one bucket, so any query is a perfect vector match for any page.
@Test func injectedEmbedderIsUsed() async throws {
    let url = tempDBURL()
    let db = try AppDatabase.open(at: url)
    try await db.writer.write { d in
        _ = try WikiStore.insert(WikiPage(slug: "fjord-trip", type: .project, title: "Fjord trip", aliases: [],
                                          summary: "Boat excursion.", body: "", links: [], mentionCount: 3,
                                          firstSeen: Date(), lastSeen: Date(), snapshotIDs: [], updatedAt: Date(),
                                          llmCallID: nil), in: d)
    }
    let embedder = HashingEmbedder(dimension: 1)
    _ = try await EmbeddingIndexer(db: db, embedder: embedder).run(limit: 100, at: Date(),
                                                                   generation: try DataGeneration.current(db))
    // No word in common: full-text search alone finds nothing.
    let ftsOnly = await MemoryTools(databaseURL: url, embedder: { nil }).call("search_wiki", arguments: ["query": "zebra"])
    #expect(try #require(try decode(ftsOnly.text) as? [Any]).isEmpty)
    let shared = await MemoryTools(databaseURL: url, embedder: { embedder }).call("search_wiki", arguments: ["query": "zebra"])
    let rows = try #require(try decode(shared.text) as? [[String: Any]])
    #expect(rows.map { $0["slug"] as? String } == ["fjord-trip"])
}

@Test func recordedMeetingSearchIsRecognizedAndRequiresItsOwnPermission() async throws {
    let url = try seededDB(texts: [])
    let tool = MemoryTools(databaseURL: url)
    let result = await tool.call("search_recorded_meetings", arguments: ["query": "telescope"])
    #expect(result.isError && result.text.contains("Meeting sources"))
}

@Test func mcpReadsMatchingRecordingPassagesAndRechecksAccessOnEveryCall() async throws {
    let url = tempDBURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let db = try AppDatabase.open(at: url)
    try await db.writer.write { d in
        try d.execute(sql: """
            INSERT INTO local_meetings(id, started_at, client, title, transcript, notes, interrupted, source_app, source_bundle)
            VALUES(?, CURRENT_TIMESTAMP, 'Teams', 'Planning', ?, 'Ship Friday', 1, 'Teams', 'com.example.teams')
            """, arguments: [UUID(), String(repeating: "hello ", count: 1500) + "\n[12:34] Mira: Prepare the telescope"])
    }
    let tools = MemoryTools(databaseURL: url)
    let name = "search_recorded_meetings"
    try RecordingSearchAccess.chat.set(true, in: db)
    #expect(await tools.call(name, arguments: [:]).isError)
    try RecordingSearchAccess.mcp.set(true, in: db)
    let hit = await tools.call(name, arguments: ["query": "teles"])
    let rows = try #require(try decode(hit.text) as? [[String: Any]])
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    let excerpt = try #require(row["transcript_excerpt"] as? String)
    #expect(excerpt.contains("[12:34] Mira: Prepare the telescope") && excerpt.count <= 1800)
    #expect(row["interrupted"] as? Bool == true && row["notes_excerpt"] as? String == "Ship Friday")
    let notesHit = await tools.call(name, arguments: ["query": "Friday"])
    #expect(!notesHit.isError && notesHit.text.contains("Ship Friday"))
    #expect(!notesHit.text.contains("source_bundle"))
    try ExclusionStore(db).add("app:Teams")
    #expect(try (decode(await tools.call(name, arguments: [:]).text) as? [Any])?.isEmpty == true)
    try ExclusionStore(db).remove("app:Teams")
    try SettingsStore(db).pause(until: .distantFuture)
    #expect(await tools.call(name, arguments: [:]).isError)
    try SettingsStore(db).pause(until: nil)
    try RecordingSearchAccess.mcp.set(false, in: db)
    #expect(await tools.call(name, arguments: [:]).isError)
}
