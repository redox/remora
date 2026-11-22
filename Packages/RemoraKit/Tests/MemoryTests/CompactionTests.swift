import Embeddings
import Foundation
import GRDB
import LLM
import LLMTestSupport
import Storage
import Synchronization
import Testing
@testable import Memory

// Nightly compaction at 2026-11-21 03:30 (Europe/Paris).

private let dayS: TimeInterval = 86_400

private struct NoEmbedder: Embedder {
    func identity() async -> EmbedderIdentity? { nil }
    func embed(_ text: String) async throws -> [Float] { throw EmbeddingError.unavailable }
}

private struct ZeroDimensionEmbedder: Embedder {
    func identity() async -> EmbedderIdentity? { EmbedderIdentity(modelID: "zero", revision: 1, dimension: 0) }
    func embed(_ text: String) async throws -> [Float] { [] }
}

/// `HashingEmbedder` that counts its calls.
private final class CountingEmbedder: Embedder {
    private let base = HashingEmbedder()
    private let count = Mutex(0)
    var calls: Int { count.withLock { $0 } }
    func identity() async -> EmbedderIdentity? { await base.identity() }
    func embed(_ text: String) async throws -> [Float] {
        count.withLock { $0 += 1 }
        return try await base.embed(text)
    }
}

/// Cancels the task running compaction when the embedding step asks for its identity.
private struct CancellingEmbedder: Embedder {
    func identity() async -> EmbedderIdentity? {
        withUnsafeCurrentTask { $0?.cancel() }
        return EmbedderIdentity(modelID: "hashing", revision: 1, dimension: 64)
    }
    func embed(_ text: String) async throws -> [Float] { try await HashingEmbedder().embed(text) }
}

private let compactionJob = Job(kind: .compaction, periodKey: "2026-11-21", periodStart: date(2026, 11, 21),
                                periodEnd: date(2026, 11, 22), nextRunAt: cpNow, createdAt: cpNow)

private func digestJSON(_ text: String) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: ["digest": text]), as: UTF8.self)
}

/// An hour chronicle `[start, start + 1 h)`.
@discardableResult
private func hourRow(_ db: AppDatabase, _ start: Date, ids: [Int64], summary: String = "An hour",
                     generatedAt: Date? = nil) throws -> Chronicle {
    try db.writer.write { d in
        try ChronicleStore(db).upsert(Chronicle(
            level: .hour, periodKey: PeriodKey.key(.hour, for: start, calendar: paris), periodStart: start,
            periodEnd: start.addingTimeInterval(3_600), summary: summary,
            metadata: Chronicle.Metadata(entitiesDone: true), snapshotIDs: ids, generatedAt: generatedAt ?? start), in: d)
    }
}

/// A snapshot `daysAgo` old, covered by its own hour chronicle unless `covered` is false.
private func oldSnapshot(_ db: AppDatabase, _ text: String, daysAgo: Double, covered: Bool = true) throws -> Int64 {
    let at = cpNow.addingTimeInterval(-daysAgo * dayS)
    let id = try #require(try seedSnapshot(db, text, at: at).id)
    if covered {
        let start = paris.dateInterval(of: .hour, for: at)!.start
        try hourRow(db, start, ids: [id])
    }
    return id
}

private func exists(_ db: AppDatabase, snapshot id: Int64) throws -> Bool {
    try !SnapshotStore(db).snapshots(ids: [id]).isEmpty
}

private func setRetention(_ db: AppDatabase, _ r: RetentionSetting) throws {
    try MemorySettings(SettingsStore(db)).setRetention(r)
}

@discardableResult
private func wikiPage(_ db: AppDatabase, _ slug: String, title: String, aliases: [String] = [], mentions: Int = 1,
                      lastSeen: Date) throws -> WikiPage {
    try db.writer.write { d in
        try WikiStore.insert(WikiPage(slug: slug, type: .person, title: title, aliases: aliases, mentionCount: mentions,
                                      firstSeen: lastSeen, lastSeen: lastSeen, updatedAt: lastSeen), in: d)
    }
}

private func addFact(_ db: AppDatabase, _ slug: String, _ text: String, invalid: Bool) throws {
    try db.writer.write { d in
        _ = try WikiStore.insert(WikiFact(slug: slug, fact: text, normKey: TextFold.key(text), subject: .thirdParty,
                                          basis: .onScreenContent, worth: .core, snapshotIDs: [1], validAt: cpNow,
                                          invalidAt: invalid ? cpNow : nil, recordedAt: cpNow, lastConfirmedAt: cpNow),
                                 in: d)
    }
}

private func count(_ db: AppDatabase, _ sql: String) throws -> Int {
    try db.reader.read { try Int.fetchOne($0, sql: sql) ?? 0 }
}

// MARK: - Retention

@Test func foreverRetentionDeletesNothing() async throws {
    let env = try compactionEnv()
    let old = try oldSnapshot(env.db, "Covered and uncited", daysAgo: 400)
    try setRetention(env.db, .forever)
    let report = try await env.compaction.compact(context: compactionContext())
    #expect(report.snapshotsDeleted == 0)
    #expect(try exists(env.db, snapshot: old))
    #expect(report.skippedSteps.isEmpty)

    // The same row goes once a window applies (the fixture is deletable, so the check above means something).
    try setRetention(env.db, .days(30))
    let windowed = try await env.compaction.compact(context: compactionContext())
    #expect(windowed.snapshotsDeleted == 1)
    #expect(try !exists(env.db, snapshot: old))
}

@Test func loweringRetentionTo7Days() async throws {
    let env = try compactionEnv()
    let s1 = try oldSnapshot(env.db, "Forty days old", daysAgo: 40)
    let s6 = try oldSnapshot(env.db, "Ten days old", daysAgo: 10)
    let cited = try oldSnapshot(env.db, "Ten days old and cited", daysAgo: 10.5)
    let uncovered = try oldSnapshot(env.db, "Ten days old, never summarised", daysAgo: 11, covered: false)
    try wikiPage(env.db, "ada", title: "Ada", mentions: 3, lastSeen: cpNow)
    try db(env.db) { d in
        _ = try WikiStore.insert(WikiFact(slug: "ada", fact: "Ada joined", normKey: "ada joined", subject: .thirdParty,
                                          basis: .onScreenContent, worth: .core, snapshotIDs: [cited], validAt: cpNow,
                                          recordedAt: cpNow, lastConfirmedAt: cpNow), in: d)
    }

    let at30 = try await env.compaction.compact(context: compactionContext())
    #expect(at30.snapshotsDeleted == 1)
    #expect(try !exists(env.db, snapshot: s1) && exists(env.db, snapshot: s6))

    try setRetention(env.db, .days(7))
    let at7 = try await env.compaction.compact(context: compactionContext())
    #expect(at7.snapshotsDeleted == 1)
    #expect(try !exists(env.db, snapshot: s6))
    #expect(try exists(env.db, snapshot: cited) && exists(env.db, snapshot: uncovered))
    // Chronicles outlive their snapshots (F-61): the hour still records what it summarised.
    #expect(try count(env.db, "SELECT COUNT(*) FROM chronicle WHERE level = 'hour' AND is_dirty = 0") == 3)
}

private func db(_ db: AppDatabase, _ body: (Database) throws -> Void) throws {
    try db.writer.write { try body($0) }
}

// MARK: - Wiki prune

@Test func prunesOnlyStaleSingleMentionPagesWithoutFactsOrLoops() async throws {
    let env = try compactionEnv()
    let old = cpNow.addingTimeInterval(-40 * dayS)
    let stale = try wikiPage(env.db, "stale", title: "Stale Person", lastSeen: old)
    try wikiPage(env.db, "twice", title: "Twice Seen", mentions: 2, lastSeen: old)
    try wikiPage(env.db, "recent", title: "Recent Person", lastSeen: cpNow.addingTimeInterval(-5 * dayS))
    try wikiPage(env.db, "history", title: "Has History", lastSeen: old)
    try addFact(env.db, "history", "Has History used to work at Acme", invalid: true)
    try wikiPage(env.db, "lea", title: "Léa Martin", lastSeen: old)
    try wikiPage(env.db, "oslo", title: "Offsite", aliases: ["Oslo Offsite 2026"], lastSeen: old)
    // Named by open flags (folded): the person of one, the project of another (via an alias).
    try seedFlag(env.db, .todo, "Call back about dinner", owner: .other, person: "lea martin", created: cpNow)
    try seedFlag(env.db, .event, "Offsite kickoff", owner: .other, project: "oslo offsite 2026", created: cpNow)
    // A done flag does not protect its page.
    try wikiPage(env.db, "closed", title: "Closed Loop", lastSeen: old)
    try seedFlag(env.db, .todo, "Thank Closed Loop", owner: .other, person: "Closed Loop", created: cpNow, status: .done)
    try db(env.db) { d in
        try EmbeddingStore.upsert(owner: .wikiPage, ownerID: stale.id!, identity: EmbedderIdentity(modelID: "hashing", revision: 1, dimension: 64),
                                  vector: [Float](repeating: 0.125, count: 64), contentHash: "x", at: cpNow, in: d)
    }

    let report = try await env.compaction.compact(context: compactionContext(cloudAllowed: false))

    #expect(report.pagesPruned == 2)
    let left = try await env.db.reader.read { try String.fetchAll($0, sql: "SELECT slug FROM wiki_pages ORDER BY slug") }
    #expect(left == ["history", "lea", "oslo", "recent", "twice"])
    #expect(try count(env.db, "SELECT COUNT(*) FROM embeddings WHERE owner_table = 'wiki_pages' AND owner_id = \(stale.id!)") == 0)
}

// MARK: - Loops

@Test func agedLoopsExpireNeverDone() async throws {
    let env = try compactionEnv()
    let todo = try seedFlag(env.db, .todo, "Renew the passport", created: cpNow.addingTimeInterval(-20 * dayS),
                            lastSeen: cpNow.addingTimeInterval(-15 * dayS))
    let commitment = try seedFlag(env.db, .commitment, "Review Léa's draft", owner: .other,
                                  created: cpNow.addingTimeInterval(-20 * dayS), lastSeen: cpNow.addingTimeInterval(-13 * dayS))
    let event = try seedFlag(env.db, .event, "Dentist", created: cpNow.addingTimeInterval(-5 * dayS),
                             due: cpNow.addingTimeInterval(-2 * dayS))
    let soon = try seedFlag(env.db, .event, "Team lunch", created: cpNow.addingTimeInterval(-5 * dayS),
                            due: cpNow.addingTimeInterval(-12 * 3_600))
    let email = try seedFlag(env.db, .email, "Budget email from finance", created: cpNow.addingTimeInterval(-40 * dayS))

    let report = try await env.compaction.compact(context: compactionContext(cloudAllowed: false))

    #expect(report.loopsExpired == 2)
    for f in [todo, event] {
        let row = try #require(try flagRow(env.db, f.id))
        #expect(row.status == .expired && row.closedAt == cpNow && row.closeSnapshotIDs.isEmpty)
    }
    for f in [commitment, soon, email] { #expect(try flagRow(env.db, f.id)?.status == .open) }
    #expect(try count(env.db, "SELECT COUNT(*) FROM salient_flags WHERE status = 'done'") == 0)
}

@Test func duplicateLoopsMerge() async throws {
    let env = try compactionEnv()
    let older = try seedFlag(env.db, .todo, "Send Marc the Oslo deck", person: "Marc", created: cpNow.addingTimeInterval(-3 * dayS),
                             ids: [1, 2])
    let newer = try seedFlag(env.db, .todo, "send marc the oslo deck now", person: "MARC",
                             created: cpNow.addingTimeInterval(-1 * dayS), ids: [2, 3])
    let other = try seedFlag(env.db, .todo, "Book flights to Oslo", person: "Marc", created: cpNow.addingTimeInterval(-dayS))
    let otherKind = try seedFlag(env.db, .commitment, "Send Marc the Oslo deck", person: "Marc",
                                 created: cpNow.addingTimeInterval(-dayS))
    let otherPerson = try seedFlag(env.db, .todo, "Send Marc the Oslo deck", person: "Léa", created: cpNow.addingTimeInterval(-dayS))

    let report = try await env.compaction.compact(context: compactionContext(cloudAllowed: false))

    #expect(report.loopsMerged == 1)
    #expect(try flagRow(env.db, newer.id) == nil)
    let survivor = try #require(try flagRow(env.db, older.id))
    #expect(survivor.snapshotIDs == [1, 2, 3])
    #expect(survivor.lastSeenAt == newer.lastSeenAt && survivor.text == older.text && survivor.status == .open)
    for f in [other, otherKind, otherPerson] { #expect(try flagRow(env.db, f.id) != nil) }
}

@Test func atMostTenLoopChecksPerNight() async throws {
    let env = try compactionEnv(.bySchema(["loop_check": loopJSON(done: false, confidence: 0.2, evidence: 0, quote: "")]))
    var flags: [SalientFlag] = []
    let tasks = ["budget sheet", "venue shortlist", "flight options", "hotel quotes", "agenda draft", "speaker notes",
                 "hiking route", "dinner booking", "badge design", "travel policy", "insurance forms", "photo release"]
    for i in 0..<12 {
        // The last two were checked most recently, so they wait for another night.
        let checked: Date? = i >= 10 ? cpNow.addingTimeInterval(-3_600) : (i % 2 == 0 ? nil : cpNow.addingTimeInterval(-5 * dayS))
        flags.append(try seedFlag(env.db, i % 2 == 0 ? .todo : .commitment, "Prepare the \(tasks[i]) for Marc Dupont",
                                  person: "Marc Dupont", created: cpNow.addingTimeInterval(-2 * dayS), checked: checked))
    }
    // Not the user's loop: never checked.
    let theirs = try seedFlag(env.db, .commitment, "Marc Dupont sends the venue list", owner: .other,
                              person: "Marc Dupont", created: cpNow.addingTimeInterval(-2 * dayS))
    try seedSnapshot(env.db, "Marc Dupont: items prepared? number 3 is pending", at: cpNow.addingTimeInterval(-dayS))

    let report = try await env.compaction.compact(context: compactionContext())

    #expect(report.loopsChecked == 10)
    #expect(env.fake.requests.count == 10)
    for f in flags.prefix(10) { #expect(try flagRow(env.db, f.id)?.checkedAt == cpNow) }
    for f in flags.suffix(2) { #expect(try flagRow(env.db, f.id)?.checkedAt == cpNow.addingTimeInterval(-3_600)) }
    #expect(try flagRow(env.db, theirs.id)?.checkedAt == nil)
}

// MARK: - Failures and the cloud gate

@Test func stepFailureDoesNotStopLaterSteps() async throws {
    // No `memory_digest` output: the digest call fails.
    let env = try compactionEnv(.bySchema([:]))
    try db(env.db) { d in
        let start = date(2026, 11, 20)
        try ChronicleStore(env.db).upsert(Chronicle(level: .day, periodKey: "2026-11-20", periodStart: start,
                                                    periodEnd: date(2026, 11, 21), summary: "Prepared the offsite.",
                                                    generatedAt: start), in: d)
    }
    let old = try oldSnapshot(env.db, "Old and covered", daysAgo: 45)

    let report = try await env.compaction.compact(context: compactionContext())

    #expect(report.skippedSteps == ["digest"])
    #expect(!report.digestRebuilt)
    #expect(report.snapshotsDeleted == 1)
    #expect(try !exists(env.db, snapshot: old))
    #expect(report.embeddingsWritten > 0)
}

@Test func cloudDeniedSkipsLLMStepsOnly() async throws {
    let env = try compactionEnv(.bySchema(["loop_check": loopJSON(done: true, confidence: 1, evidence: 1, quote: "x"),
                                           "memory_digest": digestJSON("### Current focus\nX")]))
    try db(env.db) { d in
        let start = date(2026, 11, 20)
        var day = Chronicle(level: .day, periodKey: "2026-11-20", periodStart: start, periodEnd: date(2026, 11, 21),
                            summary: "Prepared the offsite.", isDirty: true, generatedAt: start)
        try day.insert(d)
    }
    _ = try JobStore(env.db).enqueue([JobSpec(kind: .dayRollup, periodKey: "2026-11-20", periodStart: date(2026, 11, 20),
                                              periodEnd: date(2026, 11, 21), notBefore: date(2026, 11, 21))], now: date(2026, 11, 21))
    let job = try #require(try JobStore(env.db).job(kind: .dayRollup, periodKey: "2026-11-20"))
    try JobStore(env.db).complete(id: try #require(job.id), status: .done, now: date(2026, 11, 21))
    let loop = try seedFlag(env.db, .todo, "Send Marc Dupont the deck", person: "Marc Dupont", created: cpNow.addingTimeInterval(-dayS))
    try seedSnapshot(env.db, "Here is the deck, Marc Dupont", at: cpNow.addingTimeInterval(-3_600))
    let old = try oldSnapshot(env.db, "Old and covered", daysAgo: 45)
    try wikiPage(env.db, "stale", title: "Stale", lastSeen: cpNow.addingTimeInterval(-60 * dayS))

    let report = try await env.compaction.compact(context: compactionContext(cloudAllowed: false))

    #expect(env.fake.requests.isEmpty)
    #expect(report.skippedSteps == ["loop_checks", "digest"])
    #expect(report.loopsChecked == 0 && !report.digestRebuilt)
    #expect(try flagRow(env.db, loop.id)?.checkedAt == nil)
    // Everything that needs no model still ran.
    #expect(report.rerollsQueued == 1)
    #expect(try JobStore(env.db).status(kind: .dayRollup, periodKey: "2026-11-20") == .pending)
    #expect(report.pagesPruned == 1)
    #expect(report.snapshotsDeleted == 1)
    #expect(try !exists(env.db, snapshot: old))
    #expect(report.embeddingsWritten > 0)
}

@Test func staleGenerationWritesNothing() async throws {
    let env = try compactionEnv()
    let old = try oldSnapshot(env.db, "Old and covered", daysAgo: 45)
    let todo = try seedFlag(env.db, .todo, "Renew the passport", created: cpNow.addingTimeInterval(-20 * dayS),
                            lastSeen: cpNow.addingTimeInterval(-15 * dayS))
    try SettingsStore(env.db).setValue(1, forKey: "memory.dataGeneration")

    let report = try await env.compaction.compact(context: compactionContext(generation: 0, cloudAllowed: false))

    #expect(try exists(env.db, snapshot: old))
    #expect(try flagRow(env.db, todo.id)?.status == .open)
    #expect(report.snapshotsDeleted == 0 && report.loopsExpired == 0 && report.embeddingsWritten == 0)
    #expect(try count(env.db, "SELECT COUNT(*) FROM embeddings") == 0)
    #expect(try SettingsStore(env.db).value(CompactionReport.self, forKey: CompactionPipeline.lastReportKey) == nil)
}

// MARK: - Requeue, boilerplate, style

@Test func requeuesDirtyRollupsButNotHours() async throws {
    let env = try compactionEnv()
    let jobs = JobStore(env.db)
    try db(env.db) { d in
        var day = Chronicle(level: .day, periodKey: "2026-11-19", periodStart: date(2026, 11, 19),
                            periodEnd: date(2026, 11, 20), summary: "Day", isDirty: true, generatedAt: cpNow)
        try day.insert(d)
        var week = Chronicle(level: .week, periodKey: "2026-W47", periodStart: date(2026, 11, 16),
                             periodEnd: date(2026, 11, 23), summary: "Week", isDirty: true, generatedAt: cpNow)
        try week.insert(d)
        var hour = Chronicle(level: .hour, periodKey: "2026-11-19T10+0100", periodStart: date(2026, 11, 19, 10),
                             periodEnd: date(2026, 11, 19, 11), summary: "Hour", isDirty: true, generatedAt: cpNow)
        try hour.insert(d)
    }
    for (kind, key) in [(JobKind.dayRollup, "2026-11-19"), (.hour, "2026-11-19T10+0100")] {
        _ = try jobs.enqueue([JobSpec(kind: kind, periodKey: key, notBefore: date(2026, 11, 20))], now: date(2026, 11, 20))
        try jobs.complete(id: try #require(try jobs.job(kind: kind, periodKey: key)?.id), status: .done, now: date(2026, 11, 20))
    }

    let report = try await env.compaction.compact(context: compactionContext(cloudAllowed: false))

    #expect(report.rerollsQueued == 2)
    #expect(try jobs.status(kind: .dayRollup, periodKey: "2026-11-19") == .pending)
    // A dirty week with no job row gets one.
    let week = try #require(try jobs.job(kind: .weekRollup, periodKey: "2026-W47"))
    #expect(week.status == .pending && week.periodStart == date(2026, 11, 16) && week.periodEnd == date(2026, 11, 23))
    #expect(try jobs.status(kind: .hour, periodKey: "2026-11-19T10+0100") == .done)
}

@Test func boilerplateRefreshPrunesAndLearns() async throws {
    let env = try compactionEnv()
    try db(env.db) { d in
        try d.execute(sql: "INSERT INTO boilerplate_surfaces (surface, docs) VALUES ('app:x', 25)")
        try d.execute(sql: "INSERT INTO boilerplate_stats (surface, line_hash, line_text, docs) VALUES ('app:x', 'a', 'Sign in', 22)")
        try d.execute(sql: "INSERT INTO boilerplate_stats (surface, line_hash, line_text, docs) VALUES ('app:x', 'b', 'Rare line', 0.5)")
    }
    let report = try await env.compaction.compact(context: compactionContext(cloudAllowed: false))
    #expect(report.boilerplateLearned == 1 && report.boilerplateForgotten == 0)
    #expect(try count(env.db, "SELECT COUNT(*) FROM boilerplate_stats WHERE line_hash = 'b'") == 0)
}

@Test func styleMergeOnlyTouchesModelOwnedNotes() async throws {
    let env = try compactionEnv()
    let call = try LLMCallStore(env.db).insert(LLMCall(startedAt: cpNow, durationMs: 1, backend: "siwc", model: "gpt-6-luna",
                                                       jobType: "style_consolidation", status: .completed))
    let updated = date(2026, 11, 18)
    let notes = StyleNoteStore(env.db)
    try notes.upsert(surface: "app:slack", notes: "- Casual tone\n- casual tone!\n- Short sentences\n", llmCallID: call.id, at: updated)
    let userNote = "- Formal\n- formal\nI write long prose here."
    try notes.upsert(surface: "app:mail", notes: userNote, llmCallID: nil, at: updated)

    let report = try await env.compaction.compact(context: compactionContext(cloudAllowed: false))

    #expect(report.styleRulesMerged == 1)
    let slack = try #require(try notes.row(for: "app:slack"))
    #expect(slack.notes == "- casual tone!\n- Short sentences\n")
    #expect(slack.updatedAt == updated && slack.llmCallID == call.id)
    #expect(try notes.row(for: "app:mail")?.notes == userNote)
}

// MARK: - Embeddings

@Test func embeddingsAreWrittenUntilNothingIsPending() async throws {
    let env = try compactionEnv()
    for i in 0..<3 { try hourRow(env.db, date(2026, 11, 19, 9 + i), ids: [], summary: "Worked on item \(i)") }
    let report = try await env.compaction.compact(context: compactionContext(cloudAllowed: false))
    #expect(report.embeddingsWritten == 3)
    #expect(try EmbeddingStore(env.db).pendingSourceCount(identity: EmbeddingIdentity(modelID: "hashing", revision: 1)) == 0)
}

@Test func unavailableEmbedderNeverLoops() async throws {
    // No identity, or one with no dimension: only orphan vectors go, no round runs.
    for embedder in [NoEmbedder() as any Embedder, ZeroDimensionEmbedder()] {
        let env = try compactionEnv(embedder: embedder)
        for i in 0..<3 { try hourRow(env.db, date(2026, 11, 19, 9 + i), ids: [], summary: "Worked on item \(i)") }
        try db(env.db) { d in
            try EmbeddingStore.upsert(owner: .chronicle, ownerID: 999, identity: EmbedderIdentity(modelID: "m", revision: 1, dimension: 2),
                                      vector: [1, 0], contentHash: "x", at: cpNow, in: d)
        }
        let report = try await env.compaction.compact(context: compactionContext(cloudAllowed: false))
        #expect(report.embeddingsWritten == 0)
        #expect(report.skippedSteps == ["loop_checks", "digest", "embeddings"])
        #expect(try count(env.db, "SELECT COUNT(*) FROM embeddings") == 0)
    }

    // Available, but the rows stay pending after a round (edited after the run's `at`): the loop
    // stops at the first round without progress instead of spinning on the pending count.
    let counting = CountingEmbedder()
    let env = try compactionEnv(embedder: counting)
    for i in 0..<3 {
        try hourRow(env.db, date(2026, 11, 19, 9 + i), ids: [], summary: "Worked on item \(i)",
                    generatedAt: cpNow.addingTimeInterval(3_600))
    }
    let report = try await env.compaction.compact(context: compactionContext(cloudAllowed: false))
    #expect(counting.calls == 3)
    #expect(report.embeddingsWritten == 3)
    #expect(try EmbeddingStore(env.db).pendingSourceCount(identity: EmbeddingIdentity(modelID: "hashing", revision: 1)) == 3)
}

@Test func embeddingsPipelineRunsOneBatchOrSkips() async throws {
    let db = try AppDatabase.inMemory()
    for i in 0..<3 { try hourRow(db, date(2026, 11, 19, 9 + i), ids: [], summary: "Worked on item \(i)") }
    let job = Job(kind: .embeddings, periodKey: "2026-11-21T03+0100", nextRunAt: cpNow, createdAt: cpNow)
    let off = try await EmbeddingsPipeline(db: db, embedder: NoEmbedder()).run(job, context: compactionContext())
    #expect(off == .skipped("unavailable"))
    let on = try await EmbeddingsPipeline(db: db, embedder: HashingEmbedder()).run(job, context: compactionContext())
    #expect(on == .done)
    #expect(try count(db, "SELECT COUNT(*) FROM embeddings") == 3)
}

// MARK: - Maintenance and the report

@Test func vacuumWeekly() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "remora-compaction-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appending(path: "memory.sqlite")
    let db = try AppDatabase.open(at: url)
    let env = try compactionEnv(db: db, dbURL: url)
    let settings = SettingsStore(db)
    for i in 0..<50 { try seedSnapshot(db, "Filler text number \(i) " + String(repeating: "x", count: 2_000), at: cpNow.addingTimeInterval(-Double(i) * 60)) }

    try settings.setValue(cpNow.addingTimeInterval(-3 * dayS), forKey: CompactionPipeline.lastVacuumKey)
    let recent = try await env.compaction.compact(context: compactionContext(cloudAllowed: false))
    #expect(!recent.vacuumed)
    #expect(recent.bytesBefore > 0 && recent.bytesAfter > 0)
    #expect(try settings.value(Date.self, forKey: CompactionPipeline.lastVacuumKey) == cpNow.addingTimeInterval(-3 * dayS))

    try settings.setValue(cpNow.addingTimeInterval(-8 * dayS), forKey: CompactionPipeline.lastVacuumKey)
    let due = try await env.compaction.compact(context: compactionContext(cloudAllowed: false))
    #expect(due.vacuumed)
    #expect(due.skippedSteps == ["loop_checks", "digest"])
    #expect(try settings.value(Date.self, forKey: CompactionPipeline.lastVacuumKey) == cpNow)
}

@Test func reportIsCountsOnly() async throws {
    let env = try compactionEnv(.bySchema(["loop_check": loopJSON(done: false, confidence: 0.1, evidence: 0, quote: "")]))
    let marker = "zanzibar"
    _ = try oldSnapshot(env.db, "Old \(marker) snapshot", daysAgo: 45)
    try wikiPage(env.db, "\(marker)-page", title: "\(marker) Person", lastSeen: cpNow.addingTimeInterval(-60 * dayS))
    try seedFlag(env.db, .todo, "Send the \(marker) file", person: "\(marker) Person", created: cpNow.addingTimeInterval(-dayS))
    try seedSnapshot(env.db, "The \(marker) file for \(marker) Person", at: cpNow.addingTimeInterval(-3_600))
    let job = Job(kind: .compaction, periodKey: "2026-11-21", nextRunAt: cpNow, createdAt: cpNow)

    #expect(try await env.compaction.run(job, context: compactionContext()) == .done)

    let raw = try #require(try await env.db.reader.read {
        try String.fetchOne($0, sql: "SELECT value FROM settings WHERE key = ?", arguments: [CompactionPipeline.lastReportKey])
    })
    #expect(!raw.lowercased().contains(marker))
    let saved = try #require(try SettingsStore(env.db).value(CompactionReport.self, forKey: CompactionPipeline.lastReportKey))
    #expect(saved.startedAt == cpNow && saved.snapshotsDeleted == 1 && saved.pagesPruned == 0 && saved.loopsChecked == 1)
    #expect(CompactionPipeline.lastReportKey == "memory.compaction.last")
}

// MARK: - Fix round 1: night cap, cancellation, usage limit, unsummarisable rows

@Test func secondRunOnTheSameNightMakesNoLoopChecks() async throws {
    let env = try compactionEnv(.bySchema(["loop_check": loopJSON(done: false, confidence: 0.2, evidence: 0, quote: "")]))
    let tasks = ["budget sheet", "venue shortlist", "flight options", "hotel quotes", "agenda draft", "speaker notes",
                 "hiking route", "dinner booking", "badge design", "travel policy", "insurance forms", "photo release"]
    for (i, task) in tasks.enumerated() {
        try seedFlag(env.db, i % 2 == 0 ? .todo : .commitment, "Prepare the \(task) for Marc Dupont",
                     person: "Marc Dupont", created: cpNow.addingTimeInterval(-2 * dayS))
    }
    try seedSnapshot(env.db, "Marc Dupont: how is the preparation going?", at: cpNow.addingTimeInterval(-dayS))

    #expect(try await env.compaction.run(compactionJob, context: compactionContext()) == .done)
    #expect(env.fake.requests.count == 10)
    // Same night, two flags still never checked: the night's 10 calls are spent.
    let again = try await env.compaction.compact(context: compactionContext(now: cpNow.addingTimeInterval(1_800)))
    #expect(env.fake.requests.count == 10)
    #expect(again.loopsChecked == 0)
    #expect(try count(env.db, "SELECT COUNT(*) FROM salient_flags WHERE checked_at IS NULL") == 2)
}

@Test func cancellationMidRunPropagates() async throws {
    let env = try compactionEnv(embedder: CancellingEmbedder())
    for i in 0..<3 { try hourRow(env.db, date(2026, 11, 19, 9 + i), ids: [], summary: "Worked on item \(i)") }
    let old = try oldSnapshot(env.db, "Old and covered", daysAgo: 45)
    let task = Task { try await env.compaction.run(compactionJob, context: compactionContext(cloudAllowed: false)) }
    let result = await task.result
    #expect(throws: CancellationError.self) { try result.get() }
    // Steps before the embeddings ran; nothing after them did, and no report was saved.
    #expect(try !exists(env.db, snapshot: old))
    #expect(try count(env.db, "SELECT COUNT(*) FROM embeddings") == 0)
    #expect(try SettingsStore(env.db).value(CompactionReport.self, forKey: CompactionPipeline.lastReportKey) == nil)
    #expect(try SettingsStore(env.db).value(Date.self, forKey: CompactionPipeline.lastVacuumKey) == nil)
}

@Test func usageLimitIsRethrownAfterTheOtherSteps() async throws {
    let fake = FakeLLMClient(backend: .siwc) { _ in [.fail(.usageLimit)] }
    let env = try compactionEnv(fake)
    try seedFlag(env.db, .todo, "Send Marc Dupont the deck", person: "Marc Dupont", created: cpNow.addingTimeInterval(-dayS))
    try seedSnapshot(env.db, "Here is the deck, Marc Dupont", at: cpNow.addingTimeInterval(-3_600))
    try db(env.db) { d in
        let start = date(2026, 11, 20)
        var day = Chronicle(level: .day, periodKey: "2026-11-20", periodStart: start, periodEnd: date(2026, 11, 21),
                            summary: "Prepared the offsite.", generatedAt: start)
        try day.insert(d)
    }
    let old = try oldSnapshot(env.db, "Old and covered", daysAgo: 45)

    var thrown: (any Error)?
    do { _ = try await env.compaction.run(compactionJob, context: compactionContext()) } catch { thrown = error }

    let error = try #require(thrown)
    #expect(MemoryScheduler.disposition(for: .failure(error), cancelRequested: false).isUsageLimit)
    // One call (the loop check); the digest was not attempted after the limit.
    #expect(env.fake.requests.count == 1)
    #expect(try !exists(env.db, snapshot: old))
    let saved = try #require(try SettingsStore(env.db).value(CompactionReport.self, forKey: CompactionPipeline.lastReportKey))
    #expect(saved.skippedSteps == ["loop_checks", "digest"])
    #expect(saved.snapshotsDeleted == 1 && saved.embeddingsWritten > 0)
}

/// A snapshot of `app` `daysAgo` old with no hour chronicle.
private func uncovered(_ db: AppDatabase, _ text: String, app: String, bundleID: String, daysAgo: Double) throws -> Int64 {
    try #require(try seedSnapshot(db, text, at: cpNow.addingTimeInterval(-daysAgo * dayS), app: app, bundleID: bundleID,
                                  title: "Window").id)
}

@Test func excludedUncoveredOldSnapshotsAreDeleted() async throws {
    let env = try compactionEnv()
    let excluded = try uncovered(env.db, "Slack chatter", app: "Slack", bundleID: "com.tinyspeck.slackmacgap", daysAgo: 45)
    let excludedCited = try uncovered(env.db, "Slack promise", app: "Slack", bundleID: "com.tinyspeck.slackmacgap", daysAgo: 45)
    try seedFlag(env.db, .todo, "Answer the Slack promise", created: cpNow, ids: [excludedCited])
    let excludedRecent = try uncovered(env.db, "Slack today", app: "Slack", bundleID: "com.tinyspeck.slackmacgap", daysAgo: 2)
    let allowed = try uncovered(env.db, "Notes draft", app: "Notes", bundleID: "com.apple.Notes", daysAgo: 45)
    try ExclusionStore(env.db).add("app:Slack")

    let report = try await env.compaction.compact(context: compactionContext(cloudAllowed: false))

    #expect(report.snapshotsDeleted == 1)
    #expect(try !exists(env.db, snapshot: excluded))
    #expect(try exists(env.db, snapshot: excludedCited) && exists(env.db, snapshot: excludedRecent))
    #expect(try exists(env.db, snapshot: allowed))
    #expect(!report.skippedSteps.contains("retention_excluded"))
    // Only the allowed row is still waiting for a summary (the cited one is kept for its flag).
    #expect(try RetentionStore(env.db).awaitingSummary(olderThan: cpNow.addingTimeInterval(-30 * dayS)) { _ in true } == 2)
}

@Test func exclusionLoadFailureDeletesNothing() async throws {
    let env = try compactionEnv()
    let excluded = try uncovered(env.db, "Slack chatter", app: "Slack", bundleID: "com.tinyspeck.slackmacgap", daysAgo: 45)
    let allowed = try uncovered(env.db, "Notes draft", app: "Notes", bundleID: "com.apple.Notes", daysAgo: 45)
    try ExclusionStore(env.db).add("app:Slack")
    // The exclusions cannot be read: `.denyAll` would make every row look excluded.
    try db(env.db) { try $0.execute(sql: "DROP TABLE exclusions") }

    let report = try await env.compaction.compact(context: compactionContext(cloudAllowed: false))

    #expect(report.skippedSteps.contains("retention_excluded"))
    #expect(report.snapshotsDeleted == 0)
    #expect(try exists(env.db, snapshot: excluded) && exists(env.db, snapshot: allowed))
}

@Test func zeroDimensionEmbedderSkipsTheEmbeddingsJob() async throws {
    let db = try AppDatabase.inMemory()
    try hourRow(db, date(2026, 11, 19, 9), ids: [], summary: "Worked")
    let job = Job(kind: .embeddings, periodKey: "2026-11-21T03+0100", nextRunAt: cpNow, createdAt: cpNow)
    #expect(try await EmbeddingsPipeline(db: db, embedder: ZeroDimensionEmbedder()).run(job, context: compactionContext())
            == .skipped("unavailable"))
    #expect(try count(db, "SELECT COUNT(*) FROM embeddings") == 0)
}

// MARK: - Final review #6, #8, #9

private func seedDay(_ db: AppDatabase) throws {
    try db.writer.write { d in
        let start = date(2026, 11, 20)
        try ChronicleStore(db).upsert(Chronicle(level: .day, periodKey: "2026-11-20", periodStart: start,
                                                periodEnd: date(2026, 11, 21), summary: "Prepared the offsite.",
                                                generatedAt: start), in: d)
    }
}

/// #6: the digest is rebuilt at most once a night.
@Test func secondCompactionOnTheSameNightMakesNoDigestCall() async throws {
    let env = try compactionEnv(.bySchema(["memory_digest": digestJSON("### Current focus\nThe offsite")]))
    try seedDay(env.db)
    #expect(try await env.compaction.run(compactionJob, context: compactionContext()) == .done)
    #expect(env.fake.requests.filter { schemaName($0) == "memory_digest" }.count == 1)
    let again = try await env.compaction.compact(context: compactionContext(now: cpNow.addingTimeInterval(1_800)))
    #expect(env.fake.requests.filter { schemaName($0) == "memory_digest" }.count == 1)
    #expect(!again.digestRebuilt)
    // The next night rebuilds it.
    _ = try await env.compaction.compact(context: compactionContext(now: cpNow.addingTimeInterval(dayS)))
    #expect(env.fake.requests.filter { schemaName($0) == "memory_digest" }.count == 2)
}

/// Through the scheduler's production path (no `jobTimeout` override → `JobKind.timeout`).
@Test func compactionJobsGetFifteenMinutesOthersFiveMinutes() throws {
    let db = try AppDatabase.inMemory()
    let production = MemoryScheduler(db: db, runners: [:], planner: nil, calendar: paris)
    #expect(production.timeout(for: .compaction) == .seconds(900))
    for kind in JobKind.allCases where kind != .compaction {
        #expect(production.timeout(for: kind) == .seconds(300), "\(kind)")
    }
    let overridden = MemoryScheduler(db: db, runners: [:], planner: nil, calendar: paris, jobTimeout: .milliseconds(50))
    #expect(overridden.timeout(for: .compaction) == .milliseconds(50))
}

private func stat(_ db: AppDatabase, _ surface: String, _ hash: String, lastSeen: Date, docs: Double = 5) throws {
    try db.writer.write { d in
        try d.execute(sql: """
            INSERT INTO boilerplate_stats (surface, line_hash, line_text, docs, last_seen_at) VALUES (?, ?, 'Sign in', ?, ?)
            """, arguments: [surface, hash, docs, lastSeen])
    }
}

/// #8: stats older than the retention window are pruned; with `.forever` they stay.
@Test func boilerplateStatsOlderThanTheRetentionWindowArePruned() async throws {
    let env = try compactionEnv()
    try setRetention(env.db, .days(30))
    try stat(env.db, "app:x", "old", lastSeen: cpNow.addingTimeInterval(-31 * dayS))
    try stat(env.db, "app:x", "new", lastSeen: cpNow.addingTimeInterval(-2 * dayS))
    _ = try await env.compaction.compact(context: compactionContext(cloudAllowed: false))
    #expect(try count(env.db, "SELECT COUNT(*) FROM boilerplate_stats WHERE line_hash = 'old'") == 0)
    #expect(try count(env.db, "SELECT COUNT(*) FROM boilerplate_stats WHERE line_hash = 'new'") == 1)

    let forever = try compactionEnv()
    try setRetention(forever.db, .forever)
    try stat(forever.db, "app:x", "old", lastSeen: cpNow.addingTimeInterval(-400 * dayS))
    _ = try await forever.compaction.compact(context: compactionContext(cloudAllowed: false))
    #expect(try count(forever.db, "SELECT COUNT(*) FROM boilerplate_stats WHERE line_hash = 'old'") == 1)
}

@Test func recordUpdatesLastSeenAt() throws {
    let db = try AppDatabase.inMemory()
    let first = cpNow.addingTimeInterval(-dayS)
    try db.writer.write { d in
        try BoilerplateStore.record(BoilerplateSample(surface: "app:x", lines: ["h": "Sign in"]), at: first, in: d)
        try BoilerplateStore.record(BoilerplateSample(surface: "app:x", lines: ["h": "Sign in"]), at: cpNow, in: d)
    }
    #expect(try db.reader.read { try Date.fetchOne($0, sql: "SELECT last_seen_at FROM boilerplate_stats") } == cpNow)
}

/// #8: stats and learned lines of surfaces the current exclusions deny are dropped (an app by any
/// name seen for its bundle id, a site by its domain); a load error drops nothing.
@Test func boilerplateOfExcludedSurfacesIsDropped() async throws {
    func seed(_ db: AppDatabase) throws {
        try seedSnapshot(db, "chat", at: cpNow.addingTimeInterval(-dayS), app: "Telegram", bundleID: "ru.keepcoder.Telegram")
        for surface in ["app:ru.keepcoder.Telegram", "web:secret.example.com", "app:com.apple.mail"] {
            try stat(db, surface, "h", lastSeen: cpNow)
            try db.writer.write { d in
                try d.execute(sql: "INSERT INTO boilerplate (surface, line_hash, line_text, learned_at) VALUES (?, 'h', 'Sign in', ?)",
                              arguments: [surface, cpNow])
                try d.execute(sql: "INSERT INTO boilerplate_surfaces (surface, docs) VALUES (?, 5)", arguments: [surface])
            }
        }
        try ExclusionStore(db).add("app:Telegram")
        try ExclusionStore(db).add("secret.example.com")
    }
    let env = try compactionEnv()
    try seed(env.db)
    let report = try await env.compaction.compact(context: compactionContext(cloudAllowed: false))
    #expect(!report.skippedSteps.contains("boilerplate_excluded"))
    #expect(try await env.db.reader.read { try String.fetchAll($0, sql: "SELECT DISTINCT surface FROM boilerplate_stats") } == ["app:com.apple.mail"])
    #expect(try await env.db.reader.read { try String.fetchAll($0, sql: "SELECT DISTINCT surface FROM boilerplate") } == ["app:com.apple.mail"])

    let broken = try compactionEnv()
    try seed(broken.db)
    try db(broken.db) { try $0.execute(sql: "DROP TABLE exclusions") }
    let skipped = try await broken.compaction.compact(context: compactionContext(cloudAllowed: false))
    #expect(skipped.skippedSteps.contains("boilerplate_excluded"))
    #expect(try count(broken.db, "SELECT COUNT(DISTINCT surface) FROM boilerplate_stats") == 3)
}

/// #9: finished jobs older than 30 days go; pending ones, recent ones and the hour job of a dirty
/// chronicle stay.
@Test func finishedJobsOlderThanThirtyDaysArePruned() async throws {
    let env = try compactionEnv()
    let jobs = JobStore(env.db)
    let old = cpNow.addingTimeInterval(-31 * dayS), recent = cpNow.addingTimeInterval(-2 * dayS)
    let rows: [(JobKind, String, Date, JobStatus?)] = [
        (.hour, "old-done", old, .done), (.timeLedger, "old-failed", old, .failed), (.workingMemory, "old-skipped", old, .skipped),
        (.hour, "old-pending", old, nil), (.hour, "recent-done", recent, .done), (.hour, "2026-10-01T10+0200", old, .done),
    ]
    for (kind, key, at, status) in rows {
        _ = try jobs.enqueue([JobSpec(kind: kind, periodKey: key, notBefore: at)], now: at)
        if let status { try jobs.complete(id: try #require(try jobs.job(kind: kind, periodKey: key)?.id), status: status, now: at) }
    }
    try db(env.db) { d in
        var hour = Chronicle(level: .hour, periodKey: "2026-10-01T10+0200", periodStart: date(2026, 10, 1, 10),
                             periodEnd: date(2026, 10, 1, 11), summary: "Hour", isDirty: true, generatedAt: old)
        try hour.insert(d)
    }
    _ = try await env.compaction.compact(context: compactionContext(cloudAllowed: false))
    let left = try await env.db.reader.read { try String.fetchAll($0, sql: "SELECT period_key FROM jobs WHERE kind <> 'compaction' ORDER BY period_key") }
    #expect(left == ["2026-10-01T10+0200", "old-pending", "recent-done"])
}
