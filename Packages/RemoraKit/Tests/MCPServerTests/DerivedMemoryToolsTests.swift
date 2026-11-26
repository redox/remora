import Embeddings
import Foundation
import GRDB
import LLM
import MCP
@testable import Storage
import Testing
@testable import MCPServer

// MARK: - Fixtures

private let cal = MemoryTools.localCalendar

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "remora-mcp-derived-\(UUID().uuidString)", directoryHint: .isDirectory)
        .appending(path: "remora.sqlite")
}

/// FTS only: tests never load `NLContextualEmbedding`.
private func tools(_ url: URL) -> MemoryTools { MemoryTools(databaseURL: url, embedder: { nil }) }

private func decode(_ text: String) throws -> Any { try JSONSerialization.jsonObject(with: Data(text.utf8)) }
private func rows(_ r: ToolResult) throws -> [[String: Any]] { try #require(try decode(r.text) as? [[String: Any]]) }
private func object(_ r: ToolResult) throws -> [String: Any] { try #require(try decode(r.text) as? [String: Any]) }

/// Noon on 2026-11-`day`, local time.
private func day(_ day: Int, hour: Int = 12) -> Date {
    cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
}

@discardableResult
private func llmCall(_ db: AppDatabase, model: String, cost: Double?, input: Int = 1_200, cached: Int = 200,
                     output: Int = 300, job: String = "hour_chronicle", backend: String = "siwc",
                     at: Date = Date()) throws -> Int64 {
    try #require(try LLMCallStore(db).insert(LLMCall(
        startedAt: at, durationMs: 5, backend: backend, model: model, jobType: job, status: .completed,
        inputTokens: input, cachedInputTokens: cached, outputTokens: output, reasoningTokens: 0, estCostUSD: cost)).id)
}

private func insertChronicle(_ level: ChronicleLevel, at date: Date, summary: String, snapshots: [Int64] = [],
                             call: Int64? = nil, in d: Database) throws {
    let component: Calendar.Component = switch level {
    case .hour: .hour
    case .day: .day
    case .week: .weekOfYear
    case .month: .month
    case .year: .year
    }
    let i = try #require(cal.dateInterval(of: component, for: date))
    let f = DateFormatter()
    f.calendar = cal; f.timeZone = cal.timeZone; f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = level == .hour ? "yyyy-MM-dd'T'HHxx" : "yyyy-MM-dd"
    var c = Chronicle(level: level, periodKey: f.string(from: i.start), periodStart: i.start, periodEnd: i.end,
                      summary: summary,
                      metadata: .init(projects: [ProjectShare(name: "Remora", apps: ["Xcode"], share: 0.6)],
                                      highlights: ["shipped the MCP tools"]),
                      snapshotIDs: snapshots, generatedAt: Date(), llmCallID: call)
    try c.insert(d)
}

@discardableResult
private func insertPage(_ slug: String, _ title: String, type: WikiPageType = .project, summary: String,
                        body: String = "", snapshots: [Int64] = [], call: Int64? = nil, links: [String] = [],
                        mentions: Int = 3, lastSeen: Date = Date(), in d: Database) throws -> WikiPage {
    try WikiStore.insert(WikiPage(slug: slug, type: type, title: title, aliases: [title.lowercased()], summary: summary,
                                  body: body, links: links, mentionCount: mentions, firstSeen: day(1),
                                  lastSeen: lastSeen, snapshotIDs: snapshots, updatedAt: Date(), llmCallID: call), in: d)
}

@discardableResult
private func insertFact(_ slug: String, _ fact: String, snapshots: [Int64] = [], call: Int64? = nil,
                        invalidAt: Date? = nil, in d: Database) throws -> WikiFact {
    try WikiStore.insert(WikiFact(slug: slug, fact: fact, normKey: TextFold.key(fact), subject: .user,
                                  basis: .observedAction, worth: .core, snapshotIDs: snapshots, validAt: day(2),
                                  invalidAt: invalidAt, recordedAt: day(2), lastConfirmedAt: day(3),
                                  llmCallID: call), in: d)
}

private func insertWorkingMemory(_ text: String, relevance: Double = 0.9, snapshots: [Int64] = [], call: Int64? = nil,
                                 seen: Date = Date(), in d: Database) throws {
    var item = WorkingMemoryItem(text: text, kind: "task", normKey: TextFold.key(text), relevance: relevance,
                                 snapshotIDs: snapshots, addedAt: seen, lastSeenAt: seen, llmCallID: call)
    try item.insert(d)
}

private func insertFlag(_ text: String, kind: FlagKind = .todo, due: Date? = nil, seen: Date = Date(),
                        snapshots: [Int64] = [], call: Int64? = nil, in d: Database) throws {
    var f = SalientFlag(kind: kind, text: text, owner: .user, person: "Ana", project: "Remora", dueAt: due,
                        snapshotIDs: snapshots, dedupeKey: UUID().uuidString, createdAt: seen, lastSeenAt: seen,
                        llmCallID: call)
    try f.insert(d)
}

private func memoryDB() throws -> (URL, AppDatabase) {
    let url = tempURL()
    return (url, try AppDatabase.open(at: url))
}

// MARK: - Definitions

@Test func derivedToolsCarryUntrustedNotice() {
    let derived = ["get_chronicle", "get_working_memory", "get_attention_context", "search_wiki", "get_wiki_page",
                   "list_wiki"]
    for name in derived {
        let d = MemoryTools.definitions.first { $0.name == name }
        #expect(d?.description.hasSuffix(MemoryTools.derivedNotice) == true, "\(name)")
    }
    #expect(MemoryTools.serverInstructions.contains(
        "Derived memory (chronicles, wiki, working memory, attention context) is model-generated from the same untrusted captures."))
}

@Test func everyDefinedToolHasItsOwnCase() async throws {
    let (url, db) = try memoryDB()
    withExtendedLifetime(db) {}
    let t = tools(url)
    for d in MemoryTools.definitions {
        let r = await t.call(d.name, arguments: [:])
        #expect(!r.text.hasPrefix("Unknown tool"), "\(d.name)")
    }
    let unknown = await t.call("get_secrets", arguments: [:])
    #expect(unknown.isError && unknown.text == "Unknown tool: get_secrets")
}

// MARK: - get_chronicle

@Test func chronicleHasGeneratedBy() async throws {
    let (url, db) = try memoryDB()
    // F-51: the cost the LLM service stores for the call, from the real built-in price table.
    let usage = LLMUsage(inputTokens: 1_200, cachedInputTokens: 200, outputTokens: 300, reasoningTokens: 0)
    let terraCost = try #require(PriceTable.builtIn.cost(model: "gpt-6.1-terra", usage: usage, backend: .siwc))
    #expect(abs(terraCost - 0.00251) < 1e-12)
    #expect(PriceTable.builtIn.cost(model: "house-model-x", usage: usage, backend: .siwc) == nil)
    let terra = try llmCall(db, model: "gpt-6.1-terra", cost: terraCost, at: day(18, hour: 23))
    let unpriced = try llmCall(db, model: "house-model-x", cost: nil, at: day(17, hour: 23))
    try await db.writer.write { d in
        try insertChronicle(.day, at: day(18), summary: "Shipped the MCP tools.", call: terra, in: d)
        try insertChronicle(.day, at: day(17), summary: "Planned the MCP tools.", call: unpriced, in: d)
    }
    let r = await tools(url).call("get_chronicle", arguments: ["level": "day", "date": .int(Int(day(18).timeIntervalSince1970)),
                                                                "count": 2])
    #expect(!r.isError)
    #expect(r.text.contains("\"generated_by\""))
    #expect(r.text.contains("\"model\":\"gpt-6.1-terra\""))
    let out = try rows(r)
    #expect(out.count == 2)
    let g0 = try #require(out[0]["generated_by"] as? [String: Any])
    #expect(g0["model"] as? String == "gpt-6.1-terra" && g0["backend"] as? String == "siwc")
    #expect(g0["input_tokens"] as? Int == 1_200 && g0["output_tokens"] as? Int == 300)
    #expect(g0["est_cost_usd"] as? Double == terraCost)
    #expect(g0["at"] as? Int == Int(day(18, hour: 23).timeIntervalSince1970))
    let g1 = try #require(out[1]["generated_by"] as? [String: Any])
    #expect(g1["model"] as? String == "house-model-x")
    #expect(g1["est_cost_usd"] is NSNull)
    #expect(out[0]["summary"] as? String == "Shipped the MCP tools.")
    #expect((out[0]["highlights"] as? [String]) == ["shipped the MCP tools"])
    let project = try #require((out[0]["projects"] as? [[String: Any]])?.first)
    #expect(project["name"] as? String == "Remora" && project["share"] as? Double == 0.6)
}

@Test func chronicleCountWalksBackwards() async throws {
    let (url, db) = try memoryDB()
    try await db.writer.write { d in
        for n in 15...19 { try insertChronicle(.day, at: day(n), summary: "Day \(n) summary.", in: d) }
        try insertChronicle(.day, at: day(14), summary: String(repeating: "x", count: 5_000), in: d)
    }
    let t = tools(url)
    let r = await t.call("get_chronicle", arguments: ["level": "day", "date": .int(Int(day(18).timeIntervalSince1970)),
                                                      "count": 3])
    let out = try rows(r)
    #expect(out.map { $0["period_key"] as? String } == ["2026-11-18", "2026-11-17", "2026-11-16"])
    #expect(out.allSatisfy { $0["level"] as? String == "day" })
    #expect(out[0]["start"] as? Int == Int(cal.startOfDay(for: day(18)).timeIntervalSince1970))
    // No call row behind it: generated_by is null, not missing.
    #expect(out[0]["generated_by"] is NSNull)
    // A gap day is skipped, not padded; the summary is capped at 4,000 characters.
    let long = try rows(await t.call("get_chronicle", arguments: [
        "level": "day", "date": .int(Int(day(14).timeIntervalSince1970))]))
    #expect(long.count == 1 && (long[0]["summary"] as? String)?.count == 4_000)
    let bad = await t.call("get_chronicle", arguments: ["level": "fortnight"])
    #expect(bad.isError && bad.text.contains("level"))
    let missing = await t.call("get_chronicle", arguments: [:])
    #expect(missing.isError && missing.text.contains("level"))
}

// MARK: - Wiki

@Test func wikiPageHidesInvalidFactsUnlessHistory() async throws {
    let (url, db) = try memoryDB()
    let pageCall = try llmCall(db, model: "gpt-6.1-terra", cost: 0.004, job: "wiki_writeup")
    let factCall = try llmCall(db, model: "gpt-6-luna", cost: 0.0001, job: "entity_extraction")
    try await db.writer.write { d in
        try insertPage("oslo-team", "Oslo team", summary: "The pricing team in Oslo.", body: "Long body.",
                       call: pageCall, links: ["remora"], in: d)
        try insertPage("remora", "Remora", summary: "The app.", in: d)
        try insertFact("oslo-team", "Meets on Tuesdays", call: factCall, in: d)
        try insertFact("oslo-team", "Meets on Mondays", call: factCall, invalidAt: day(4), in: d)
    }
    let t = tools(url)
    let page = try object(await t.call("get_wiki_page", arguments: ["slug": "oslo-team"]))
    #expect(page["title"] as? String == "Oslo team" && page["type"] as? String == "project")
    #expect(page["body"] as? String == "Long body." && page["links"] as? [String] == ["remora"])
    #expect(page["aliases"] as? [String] == ["oslo team"] && page["mention_count"] as? Int == 3)
    #expect((page["generated_by"] as? [String: Any])?["model"] as? String == "gpt-6.1-terra")
    let facts = try #require(page["facts"] as? [[String: Any]])
    #expect(facts.map { $0["fact"] as? String } == ["Meets on Tuesdays"])
    #expect(facts[0]["invalid_at"] is NSNull && facts[0]["basis"] as? String == "observed_action")
    // F-41: each fact carries its own call, not the page's.
    #expect((facts[0]["generated_by"] as? [String: Any])?["model"] as? String == "gpt-6-luna")
    #expect((facts[0]["generated_by"] as? [String: Any])?["est_cost_usd"] as? Double == 0.0001)

    let history = try object(await t.call("get_wiki_page", arguments: ["slug": "oslo-team", "include_history": true]))
    let all = try #require(history["facts"] as? [[String: Any]])
    #expect(Set(all.compactMap { $0["fact"] as? String }) == ["Meets on Tuesdays", "Meets on Mondays"])
    #expect(all.first { $0["fact"] as? String == "Meets on Mondays" }?["invalid_at"] as? Int
        == Int(day(4).timeIntervalSince1970))
}

@Test func unknownSlugIsFriendlyError() async throws {
    let (url, db) = try memoryDB()
    withExtendedLifetime(db) {}
    let t = tools(url)
    let r = await t.call("get_wiki_page", arguments: ["slug": "nobody"])
    #expect(r.isError && r.text == "No wiki page with that slug. Use search_wiki or list_wiki.")
    let missing = await t.call("get_wiki_page", arguments: [:])
    #expect(missing.isError && missing.text.contains("slug"))
}

@Test func searchWikiWorksWithoutEmbeddings() async throws {
    let (url, db) = try memoryDB()
    let call = try llmCall(db, model: "gpt-6.1-terra", cost: 0.002, job: "wiki_writeup")
    try await db.writer.write { d in
        try insertPage("oslo-team", "Oslo team", summary: "The pricing team in Oslo.", call: call, in: d)
        try insertPage("ana-ruiz", "Ana Ruiz", type: .person, summary: "Designer.", in: d)
        try insertFact("ana-ruiz", "Ana prefers quarterly pricing reviews", in: d)
        try insertPage("unrelated", "Unrelated", summary: "Gardening notes.", in: d)
    }
    let t = tools(url)
    let all = try rows(await t.call("search_wiki", arguments: ["query": "pricing"]))
    #expect(Set(all.compactMap { $0["slug"] as? String }) == ["oslo-team", "ana-ruiz"])
    let oslo = try #require(all.first { $0["slug"] as? String == "oslo-team" })
    #expect(oslo["title"] as? String == "Oslo team" && oslo["type"] as? String == "project")
    #expect((oslo["score"] as? Double ?? 0) > 0)
    #expect(oslo["matched_fact"] is NSNull)
    #expect((oslo["generated_by"] as? [String: Any])?["model"] as? String == "gpt-6.1-terra")
    // A fact hit is reported on its page.
    let ana = try #require(all.first { $0["slug"] as? String == "ana-ruiz" })
    #expect(ana["matched_fact"] as? String == "Ana prefers quarterly pricing reviews")
    #expect(ana["generated_by"] is NSNull)
    let people = try rows(await t.call("search_wiki", arguments: ["query": "pricing", "type": "person"]))
    #expect(people.map { $0["slug"] as? String } == ["ana-ruiz"])
    let bad = await t.call("search_wiki", arguments: ["query": "pricing", "type": "planet"])
    #expect(bad.isError && bad.text.contains("type"))
}

/// An embedder whose model never becomes ready.
private struct StuckEmbedder: Embedder {
    func identity() async -> EmbedderIdentity? {
        try? await Task.sleep(for: .seconds(60))
        return nil
    }
    func embed(_ text: String) async throws -> [Float] { throw EmbeddingError.unavailable }
}

@Test func searchWikiFallsBackToFTSWhenEmbedderIsNotReady() async throws {
    let (url, db) = try memoryDB()
    try await db.writer.write { d in _ = try insertPage("oslo-team", "Oslo team", summary: "The pricing team.", in: d) }
    let t = MemoryTools(databaseURL: url, embedder: { StuckEmbedder() }, embedderTimeout: .milliseconds(200))
    let started = ContinuousClock.now
    let out = try rows(await t.call("search_wiki", arguments: ["query": "pricing"]))
    #expect(out.map { $0["slug"] as? String } == ["oslo-team"])
    #expect(ContinuousClock.now - started < .seconds(10))
}

@Test func listWikiSortsAndPages() async throws {
    let (url, db) = try memoryDB()
    let call = try llmCall(db, model: "gpt-6.1-terra", cost: 0.003, job: "wiki_writeup")
    try await db.writer.write { d in
        try insertPage("a", "Alpha", summary: "A.", call: call, mentions: 9, lastSeen: day(1), in: d)
        try insertPage("b", "Beta", type: .person, summary: "B.", mentions: 1, lastSeen: day(3), in: d)
        try insertPage("c", "Gamma", summary: "C.", mentions: 5, lastSeen: day(2), in: d)
    }
    let t = tools(url)
    let recent = try rows(await t.call("list_wiki", arguments: [:]))
    #expect(recent.map { $0["slug"] as? String } == ["b", "c", "a"])
    let byMentions = try rows(await t.call("list_wiki", arguments: ["sort": "mentions", "limit": 2, "offset": 1]))
    #expect(byMentions.map { $0["slug"] as? String } == ["c", "b"])
    let projects = try rows(await t.call("list_wiki", arguments: ["type": "project", "sort": "mentions"]))
    #expect(projects.map { $0["slug"] as? String } == ["a", "c"])
    #expect((projects[0]["generated_by"] as? [String: Any])?["model"] as? String == "gpt-6.1-terra")
    #expect(projects[0]["mention_count"] as? Int == 9 && projects[0]["last_seen"] as? Int == Int(day(1).timeIntervalSince1970))
    let bad = await t.call("list_wiki", arguments: ["sort": "alphabetical"])
    #expect(bad.isError && bad.text.contains("sort"))
}

// MARK: - Working memory and attention context

@Test func workingMemoryIsDecayedRankedAndCarriesProvenance() async throws {
    let (url, db) = try memoryDB()
    let now = Date()
    let call = try llmCall(db, model: "gpt-6-luna", cost: 0.0002, job: "working_memory")
    let keep = try SnapshotStore(db).insert(Snapshot(capturedAt: now, app: "Notes", text: "x", contentHash: "a", source: .ax))
    try await db.writer.write { d in
        try insertWorkingMemory("Reviewing the Oslo pricing deck", relevance: 0.8, snapshots: [try #require(keep.id)],
                                call: call, seen: now.addingTimeInterval(-6 * 3_600), in: d)
        try insertWorkingMemory("Writing the MCP tools", relevance: 0.9, seen: now, in: d)
        try insertWorkingMemory("Long gone", relevance: 0.9, seen: now.addingTimeInterval(-30 * 3_600), in: d)
    }
    let out = try rows(await tools(url).call("get_working_memory", arguments: [:]))
    #expect(out.map { $0["text"] as? String } == ["Writing the MCP tools", "Reviewing the Oslo pricing deck"])
    #expect(out[1]["relevance"] as? Double == 0.4)
    #expect(out[1]["snapshot_ids"] as? [Int] == [Int(try #require(keep.id))])
    #expect(out[1]["kind"] as? String == "task")
    #expect((out[1]["generated_by"] as? [String: Any])?["model"] as? String == "gpt-6-luna")
    #expect(out[0]["generated_by"] is NSNull)
}

@Test func attentionContextShape() async throws {
    let (url, db) = try memoryDB()
    let now = Date()
    let call = try llmCall(db, model: "gpt-6.1-terra", cost: 0.01, job: "memory_digest")
    try await db.writer.write { d in
        var recent = ActivityEvent(app: "Xcode", windowTitle: "MemoryTools.swift", startedAt: now.addingTimeInterval(-300),
                                   endedAt: now.addingTimeInterval(-10))
        try recent.insert(d)
        var old = ActivityEvent(app: "Mail", startedAt: now.addingTimeInterval(-3_600), endedAt: now.addingTimeInterval(-3_000))
        try old.insert(d)
        for i in 0..<10 { try insertWorkingMemory("Thread \(i) about pricing", relevance: 0.5 + Double(i) / 100, in: d) }
        try insertChronicle(.hour, at: now.addingTimeInterval(-3_600), summary: "Worked on MCP.", call: call, in: d)
        try insertChronicle(.hour, at: now.addingTimeInterval(-7_200), summary: "Older hour.", in: d)
        try insertFlag("Send the pricing deck", due: now.addingTimeInterval(3 * 86_400), seen: now.addingTimeInterval(-5 * 86_400),
                       call: call, in: d)
        try insertFlag("Reply to Ana", seen: now.addingTimeInterval(-3_600), in: d)
        try insertFlag("Renew passport", due: now.addingTimeInterval(30 * 86_400), seen: now.addingTimeInterval(-5 * 86_400), in: d)
        try insertFlag("Old idea", seen: now.addingTimeInterval(-5 * 86_400), in: d)
        _ = try MemoryDigestStore(db).insert(MemoryDigest(body: String(repeating: "d", count: 9_000), createdAt: now,
                                                          llmCallID: call), in: d)
    }
    let o = try object(await tools(url).call("get_attention_context", arguments: [:]))
    #expect(Set(o.keys) == ["now", "activity", "working_memory", "latest_hour", "open_items", "digest"])
    #expect(abs((o["now"] as? Int ?? 0) - Int(now.timeIntervalSince1970)) < 60)
    #expect((o["activity"] as? [[String: Any]])?.map { $0["app"] as? String } == ["Xcode"])
    #expect((o["working_memory"] as? [Any])?.count == 8)
    let hour = try #require(o["latest_hour"] as? [String: Any])
    #expect(hour["summary"] as? String == "Worked on MCP." && hour["level"] as? String == "hour")
    #expect((hour["generated_by"] as? [String: Any])?["model"] as? String == "gpt-6.1-terra")
    let items = try #require(o["open_items"] as? [[String: Any]])
    #expect(items.map { $0["text"] as? String } == ["Send the pricing deck", "Reply to Ana"])
    #expect(items[0]["kind"] as? String == "todo" && items[0]["status"] as? String == "open")
    #expect(items[0]["person"] as? String == "Ana" && items[0]["project"] as? String == "Remora")
    #expect(items[0]["due_at"] is Int && items[1]["due_at"] is NSNull)
    #expect((items[0]["generated_by"] as? [String: Any])?["model"] as? String == "gpt-6.1-terra")
    let digest = try #require(o["digest"] as? [String: Any])
    #expect((digest["text"] as? String)?.count == 8_000)
    #expect((digest["generated_by"] as? [String: Any])?["est_cost_usd"] as? Double == 0.01)
}

@Test func attentionContextOnEmptyMemoryHasNulls() async throws {
    let (url, db) = try memoryDB()
    withExtendedLifetime(db) {}
    let o = try object(await tools(url).call("get_attention_context", arguments: [:]))
    #expect(o["latest_hour"] is NSNull && o["digest"] is NSNull)
    #expect((o["open_items"] as? [Any])?.isEmpty == true && (o["working_memory"] as? [Any])?.isEmpty == true)
}

@Test func limitsAreCapped() async throws {
    let (url, db) = try memoryDB()
    try await db.writer.write { d in
        for i in 0..<30 {
            try insertWorkingMemory("Item number \(i) pricing", in: d)
            try insertPage("page-\(i)", "Pricing page \(i)", summary: "About pricing \(i).", in: d)
        }
        for n in 1...30 { try insertChronicle(.day, at: day(n), summary: "Day \(n).", in: d) }
    }
    let t = tools(url)
    #expect(try rows(await t.call("get_working_memory", arguments: ["limit": 500])).count == 20)
    #expect(try rows(await t.call("list_wiki", arguments: ["limit": 500])).count == 20)
    #expect(try rows(await t.call("search_wiki", arguments: ["query": "pricing", "limit": 500])).count == 20)
    #expect(try rows(await t.call("get_chronicle", arguments: [
        "level": "day", "date": .int(Int(day(30).timeIntervalSince1970)), "count": 500])).count == 24)
    #expect(try rows(await t.call("get_working_memory", arguments: [:])).count == 12)
    #expect(try rows(await t.call("search_wiki", arguments: ["query": "pricing"])).count == 10)
}

// MARK: - Old databases and usage

@Test func preV4DatabaseIsFriendlyError() async throws {
    let url = tempURL()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    do {
        let q = try DatabaseQueue(path: url.path)
        try Migrations.make().migrate(q, upTo: "v3")
    }
    let t = tools(url)
    let calls: [(String, [String: Value])] = [
        ("get_chronicle", ["level": "day"]), ("get_working_memory", [:]), ("get_attention_context", [:]),
        ("search_wiki", ["query": "pricing"]), ("get_wiki_page", ["slug": "x"]), ("list_wiki", [:]),
    ]
    for (name, args) in calls {
        let r = await t.call(name, arguments: args)
        #expect(r.isError && r.text == MemoryTools.memoryNeedsUpdate, "\(name)")
        #expect(r.text.contains("Remora"))
    }
    #expect(MemoryTools.memoryNeedsUpdate == "Remora needs to be updated and launched once.")
    // get_usage still works on v3 and reports the background block with defaults.
    let usage = try object(await t.call("get_usage", arguments: [:]))
    let bg = try #require(usage["background"] as? [String: Any])
    #expect(Set(bg.keys) == ["backoff_until"])
}

@Test func usageBackgroundBlockReportsOnlyTheBackoff() async throws {
    let (url, db) = try memoryDB()
    let now = Date()
    try llmCall(db, model: "gpt-6-luna", cost: 0.001, input: 1_000, cached: 200, output: 300, job: "hour_chronicle")
    try llmCall(db, model: "gpt-6-luna", cost: 0.001, input: 9_000, cached: 0, output: 900, job: "rewrite")
    try llmCall(db, model: "apple", cost: 0, input: 9_000, cached: 0, output: 900, job: "working_memory",
                backend: "on_device")
    let settings = MemorySettings(SettingsStore(db))
    let until = now.addingTimeInterval(3_600)
    try settings.setBackoff(UsageBackoff(step: 1, until: until))
    let o = try object(await tools(url).call("get_usage", arguments: [:]))
    let bg = try #require(o["background"] as? [String: Any])
    #expect(Set(bg.keys) == ["backoff_until"])
    #expect(bg["backoff_until"] as? Int == Int(until.timeIntervalSince1970))
    #expect(o["totals"] is [Any] && o["note"] is String)

    try settings.setBackoff(UsageBackoff(step: 2, until: now.addingTimeInterval(-60)))
    let expired = try object(await tools(url).call("get_usage", arguments: [:]))
    #expect((expired["background"] as? [String: Any])?["backoff_until"] is NSNull)
}

// MARK: - Review Focus 4 / F-43: an app excluded after capture never appears in any tool's output

@Test func appExcludedAfterCaptureNeverAppearsInAnyTool() async throws {
    let (url, db) = try memoryDB()
    let now = Date()
    let store = SnapshotStore(db)
    let shown = try #require(try store.insert(Snapshot(capturedAt: now.addingTimeInterval(-120), app: "Notes",
                                                       text: "pricing plan visible", contentHash: "1", source: .ax)).id)
    let hidden = try #require(try store.insert(Snapshot(capturedAt: now.addingTimeInterval(-60), app: "Vault",
                                                        windowTitle: "zebracode", text: "pricing zebracode",
                                                        contentHash: "2", source: .ax)).id)
    try await db.writer.write { d in
        var focus = ActivityEvent(app: "Vault", windowTitle: "zebracode", startedAt: now.addingTimeInterval(-200),
                                  endedAt: now.addingTimeInterval(-5))
        try focus.insert(d)
        var visible = ActivityEvent(app: "Notes", startedAt: now.addingTimeInterval(-400), endedAt: now.addingTimeInterval(-300))
        try visible.insert(d)
        try insertChronicle(.hour, at: now, summary: "Pricing zebracode in Vault.", snapshots: [hidden], in: d)
        try insertChronicle(.hour, at: now.addingTimeInterval(-3_600), summary: "Pricing plan in Notes.",
                            snapshots: [shown, hidden], in: d)
        try insertChronicle(.day, at: now, summary: "Pricing zebracode Vault day.", snapshots: [hidden], in: d)
        try insertPage("vault-project", "Vault project zebracode", summary: "Pricing zebracode.", snapshots: [hidden], in: d)
        try insertFact("vault-project", "Pricing zebracode fact", snapshots: [hidden], in: d)
        try insertPage("oslo-team", "Oslo team", summary: "The pricing team.", snapshots: [shown],
                       links: ["vault-project"], in: d)
        try insertFact("oslo-team", "Owns pricing", snapshots: [shown, hidden], in: d)
        try insertFact("oslo-team", "Pricing zebracode secret fact", snapshots: [hidden], in: d)
        try insertFlag("Pricing zebracode follow-up", due: now.addingTimeInterval(86_400), snapshots: [hidden], in: d)
        try insertFlag("Pricing plan follow-up", due: now.addingTimeInterval(86_400), snapshots: [shown, hidden], in: d)
        try insertWorkingMemory("Pricing zebracode", snapshots: [hidden], in: d)
        try insertWorkingMemory("Pricing plan", snapshots: [shown, hidden], in: d)
    }
    try ExclusionStore(db).add("app:Vault")

    let t = tools(url)
    try RecordingSearchAccess.mcp.set(true, in: db)
    let nowArg = Value.int(Int(now.timeIntervalSince1970))
    let calls: [(String, [String: Value])] = [
        ("search_recorded_meetings", ["query": "pricing"]),
        ("search_memory", ["query": "pricing"]), ("get_snapshots", ["ids": [.int(Int(shown)), .int(Int(hidden))]]),
        ("read_session", ["app": "Vault", "start": 0, "end": 4_000_000_000]), ("get_recent_activity", [:]),
        ("get_usage", [:]), ("get_chronicle", ["level": "hour", "date": nowArg, "count": 3]),
        ("get_chronicle", ["level": "day", "date": nowArg]), ("get_working_memory", [:]),
        ("get_attention_context", [:]), ("search_wiki", ["query": "pricing zebracode"]),
        ("get_wiki_page", ["slug": "oslo-team", "include_history": true]), ("list_wiki", [:]),
    ]
    var outputs: [String: String] = [:]
    for (name, args) in calls {
        let r = await t.call(name, arguments: args)
        #expect(!r.isError, "\(name): \(r.text)")
        for secret in ["Vault", "vault", "zebracode"] { #expect(!r.text.contains(secret), "\(name) leaks \(secret)") }
        outputs[name, default: ""] += r.text
    }
    #expect(Set(calls.map(\.0)) == Set(MemoryTools.definitions.map(\.name)))
    // Snapshot ids handed out never include the excluded one, and it does not resolve by id.
    for (name, text) in outputs { #expect(!text.contains("\"snapshot_ids\":[\(hidden)") && !text.contains(",\(hidden)]"), "\(name)") }
    let byID = await t.call("get_snapshots", arguments: ["ids": [.int(Int(hidden))]])
    #expect(try rows(byID).isEmpty)
    let hiddenPage = await t.call("get_wiki_page", arguments: ["slug": "vault-project"])
    #expect(hiddenPage.isError && hiddenPage.text == "No wiki page with that slug. Use search_wiki or list_wiki.")
    // The allowed rows still come through, with only the allowed snapshot cited.
    #expect(outputs["get_working_memory"]?.contains("Pricing plan") == true)
    #expect(outputs["get_wiki_page"]?.contains("Owns pricing") == true)
    #expect(outputs["get_attention_context"]?.contains("Pricing plan follow-up") == true)
    #expect(outputs["get_chronicle"]?.contains("Pricing plan in Notes.") == true)
    let wm = try rows(await t.call("get_working_memory", arguments: [:]))
    #expect(wm.map { $0["snapshot_ids"] as? [Int] } == [[Int(shown)]])
    let page = try object(await t.call("get_wiki_page", arguments: ["slug": "oslo-team"]))
    #expect(page["links"] as? [String] == [])
}

/// Final review #5 (M1): with exclusions that cannot load (`.denyAll`), all six derived tools fail
/// closed: rows citing an allowed-looking snapshot, rows citing none (week rows, a page with `[]`)
/// and rows whose snapshots are all gone are withheld; arrays are empty and `digest` is null.
@Test func allSixDerivedToolsFailClosedWhenExclusionsCannotLoad() async throws {
    let (url, db) = try memoryDB()
    let now = Date()
    let shown = try #require(try SnapshotStore(db).insert(Snapshot(capturedAt: now, app: "Notes", text: "pricing",
                                                                  contentHash: "1", source: .ax)).id)
    try await db.writer.write { d in
        var event = ActivityEvent(app: "Xcode", startedAt: now.addingTimeInterval(-300), endedAt: now.addingTimeInterval(-10))
        try event.insert(d)
        try insertWorkingMemory("Pricing plan", snapshots: [shown], in: d)
        try insertWorkingMemory("Pricing thread citing nothing", in: d)
        try insertPage("oslo-team", "Oslo team", summary: "The pricing team.", snapshots: [shown], in: d)
        try insertPage("pricing-wiki", "Pricing wiki", summary: "Pricing, citing nothing.", in: d)
        try insertChronicle(.hour, at: now.addingTimeInterval(-3_600), summary: "Pricing hour, all gone.",
                            snapshots: [987_654], in: d)
        try insertChronicle(.week, at: now, summary: "Pricing week.", in: d)
        try insertFlag("Send the pricing deck", due: now.addingTimeInterval(86_400), in: d)
        _ = try MemoryDigestStore(db).insert(MemoryDigest(body: "Pricing digest", createdAt: now), in: d)
        try d.execute(sql: "DROP TABLE exclusions")
    }
    let t = tools(url)
    #expect(try rows(await t.call("get_chronicle", arguments: ["level": "hour", "count": 3])).isEmpty)
    #expect(try rows(await t.call("get_chronicle", arguments: ["level": "week"])).isEmpty)
    #expect(try rows(await t.call("get_working_memory", arguments: [:])).isEmpty)
    let o = try object(await t.call("get_attention_context", arguments: [:]))
    for key in ["activity", "working_memory", "open_items"] { #expect((o[key] as? [Any])?.isEmpty == true, "\(key)") }
    #expect(o["latest_hour"] is NSNull && o["digest"] is NSNull)
    #expect(try rows(await t.call("search_wiki", arguments: ["query": "pricing"])).isEmpty)
    let page = await t.call("get_wiki_page", arguments: ["slug": "pricing-wiki"])
    #expect(page.isError && page.text == "No wiki page with that slug. Use search_wiki or list_wiki.")
    #expect(try rows(await t.call("list_wiki", arguments: [:])).isEmpty)
}

/// Final review #4: a chronicle whose snapshots retention deleted, from an app excluded since,
/// stays hidden (judged from the tombstones); one from an app still allowed is returned.
@Test func chronicleOfAnAppExcludedAfterRetentionStaysHidden() async throws {
    let (url, db) = try memoryDB()
    let now = Date()
    let secret = try #require(try SnapshotStore(db).insert(Snapshot(capturedAt: now, app: "Slack", text: "x",
                                                                   contentHash: "s", source: .ax)).id)
    let fine = try #require(try SnapshotStore(db).insert(Snapshot(capturedAt: now, app: "Mail", text: "y",
                                                                 contentHash: "m", source: .ax)).id)
    try await db.writer.write { d in
        try insertChronicle(.hour, at: now.addingTimeInterval(-3_600), summary: "Slack hour.", snapshots: [secret], in: d)
        try insertChronicle(.hour, at: now.addingTimeInterval(-7_200), summary: "Mail hour.", snapshots: [fine], in: d)
        _ = try RetentionStore.deleteUnsummarisable([secret, fine], in: d)
    }
    try ExclusionStore(db).add("app:Slack")
    let r = try rows(await tools(url).call("get_chronicle", arguments: ["level": "hour", "count": 3]))
    #expect(r.map { $0["summary"] as? String } == ["Mail hour."])
}

/// Final review #10: the MCP tools use the app's memory calendar (auto-updating time zone).
@Test func mcpToolsShareTheMemoryCalendar() {
    #expect(MemoryTools.localCalendar == MemoryCalendar.local)
    #expect(MemoryTools.localCalendar.timeZone == TimeZone.autoupdatingCurrent)
}

@Test func attentionContextWithholdsTheDigestAfterAForget() async throws {
    let (url, db) = try memoryDB()
    let now = Date()
    try await db.writer.write { d in
        _ = try MemoryDigestStore(db).insert(MemoryDigest(body: "Pricing digest", createdAt: now), in: d)
        try ForgetMarks.mark(now: now, in: d)
    }
    let o = try object(await tools(url).call("get_attention_context", arguments: [:]))
    #expect(o["digest"] is NSNull)
}
