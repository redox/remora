import Capture
import Foundation
import GRDB
import LLM
import LLMTestSupport
import Storage
import Synchronization
import Testing
@testable import Memory

private func calls(_ db: AppDatabase) throws -> [LLMCall] { try LLMCallStore(db).recent(limit: 50).reversed() }

@Test func hourChronicleWritesRowWithProvenanceAndCall() async throws {
    let env = try pipelineEnv()
    try seedHour(env.db)
    let outcome = try await env.pipeline.run(try hourJob(env.db), context: hourContext())
    #expect(outcome == .done)

    let c = try #require(try ChronicleStore(env.db).chronicle(.hour, key: hourKey))
    #expect(c.summary.hasPrefix("The user prepared the Oslo offsite"))
    #expect(c.periodStart == hourStart && c.periodEnd == hourEnd)
    #expect(c.metadata.projects.map(\.name) == ["Oslo offsite", "Acme app"])
    #expect(c.metadata.highlights == ["Promised Marc the deck by Friday", "Oslo offsite budget is 12k€"])
    #expect(c.metadata.mergedHours == 1)
    #expect(c.metadata.apps.count == 5 && c.metadata.apps.first == "Slack")
    #expect(!c.isDirty)

    let evidence = try HourEvidence.build(db: env.db, span: hourSpan, policy: SnapshotPolicy.current(env.db))
    #expect(c.snapshotIDs == evidence.items.map(\.snapshotID))
    #expect(!c.snapshotIDs.isEmpty)

    let rows = try calls(env.db)
    let a = try #require(rows.first { $0.jobType == "hour_chronicle" })
    #expect(c.llmCallID == a.id)
    #expect(a.artifactTable == "chronicle" && a.artifactID == c.id)
    #expect(a.model == "gpt-6-luna" && a.backend == "siwc" && a.status == .completed)
    let b = try #require(rows.first { $0.jobType == "entity_extraction" })
    #expect(b.model == "gpt-6-luna" && b.artifactTable == "wiki_pages" && b.artifactID == nil)
    #expect(c.metadata.entitiesDone)

    // Both requests are strict JSON-schema calls.
    let formats = env.fake.requests.map(\.format)
    #expect(formats == [.jsonSchema(name: "hour_chronicle", schema: HourChronicleOutput.schema, strict: true),
                        .jsonSchema(name: "hour_entities", schema: HourEntitiesOutput.schema, strict: true)])
}

@Test func bothHourCallsShareInstructionsAndEvidencePrefix() async throws {
    let env = try pipelineEnv()
    try seedHour(env.db)
    _ = try await env.pipeline.run(try hourJob(env.db), context: hourContext(language: .fr))
    let r = env.fake.requests
    try #require(r.count == 2)
    #expect(r[0].instructions == r[1].instructions)
    #expect(r[0].instructions.contains(PipelinePrompt.untrusted) && r[0].instructions.contains("French"))
    #expect(r[0].input[0] == r[1].input[0])
    #expect(r[0].input.count == 2 && r[1].input.count == 2)
    #expect(r[0].input[1] != r[1].input[1])
    #expect(r.map(schemaName) == ["hour_chronicle", "hour_entities"])
}

@Test func retryAfterCallBFailureSkipsCallA() async throws {
    let failedOnce = Mutex(false)
    let fake = FakeLLMClient(backend: .siwc) { request in
        let usage = LLMUsage(inputTokens: 1_000, cachedInputTokens: 0, outputTokens: 100, reasoningTokens: 0)
        switch schemaName(request) {
        case "hour_chronicle": return [.delta(hourChronicleJSON), .complete(usage)]
        case "hour_entities":
            let fail = failedOnce.withLock { failed in defer { failed = true }; return !failed }
            return fail ? [.fail(.badRequest(code: "boom", param: nil))] : [.delta(hourEntitiesJSON), .complete(usage)]
        default: return [.fail(.badRequest(code: "fake", param: nil))]
        }
    }
    let env = try pipelineEnv(fake)
    try seedHour(env.db)
    let job = try hourJob(env.db)
    await #expect(throws: LLMError.self) { try await env.pipeline.run(job, context: hourContext()) }
    let afterFailure = try #require(try ChronicleStore(env.db).chronicle(.hour, key: hourKey))
    #expect(!afterFailure.metadata.entitiesDone)

    #expect(try await env.pipeline.run(job, context: hourContext()) == .done)
    #expect(env.fake.requests.map(schemaName) == ["hour_chronicle", "hour_entities", "hour_entities"])
    let after = try #require(try ChronicleStore(env.db).chronicle(.hour, key: hourKey))
    #expect(after.metadata.entitiesDone && after.id == afterFailure.id && after.summary == afterFailure.summary)
}

@Test func dirtyHourRerunsCallAAndClearsDirty() async throws {
    let env = try pipelineEnv()
    try seedHour(env.db)
    let job = try hourJob(env.db)
    _ = try await env.pipeline.run(job, context: hourContext())
    let first = try #require(try ChronicleStore(env.db).chronicle(.hour, key: hourKey))
    try await env.db.writer.write { try ChronicleStore(env.db).markDirty(.hour, key: hourKey, in: $0) }

    #expect(try await env.pipeline.run(job, context: hourContext()) == .done)
    // Call A again, call B not (entities are done and stay done).
    #expect(env.fake.requests.map(schemaName) == ["hour_chronicle", "hour_entities", "hour_chronicle"])
    let second = try #require(try ChronicleStore(env.db).chronicle(.hour, key: hourKey))
    #expect(!second.isDirty && second.metadata.entitiesDone && second.id == first.id)
    #expect(second.llmCallID != first.llmCallID)
}

@Test func upToDateHourMakesNoCall() async throws {
    let env = try pipelineEnv()
    try seedHour(env.db)
    let job = try hourJob(env.db)
    _ = try await env.pipeline.run(job, context: hourContext())
    #expect(try await env.pipeline.run(job, context: hourContext()) == .done)
    #expect(env.fake.requests.count == 2)
}

@Test func lateHourMarksRolledDayDirty() async throws {
    let env = try pipelineEnv()
    try seedHour(env.db)
    let store = ChronicleStore(env.db)
    let dayKey = PeriodKey.key(.day, for: hourStart, calendar: paris)
    let day = PeriodKey.interval(.day, containing: hourStart, calendar: paris)
    try await env.db.writer.write { d in
        _ = try store.upsert(Chronicle(level: .day, periodKey: dayKey, periodStart: day.start, periodEnd: day.end,
                                       summary: "Rolled before this hour was summarised", generatedAt: hourEnd), in: d)
        // Another day's chronicle is left alone.
        _ = try store.upsert(Chronicle(level: .day, periodKey: "2026-11-19", periodStart: day.start.addingTimeInterval(-86_400),
                                       periodEnd: day.start, summary: "Yesterday", generatedAt: hourEnd), in: d)
    }
    #expect(try store.chronicle(.day, key: dayKey)?.isDirty == false)
    _ = try await env.pipeline.run(try hourJob(env.db), context: hourContext())
    #expect(try store.chronicle(.day, key: dayKey)?.isDirty == true)
    #expect(try store.chronicle(.day, key: "2026-11-19")?.isDirty == false)
}

@Test func timeLedgerIsRequeuedForEveryHourOfTheSpan() async throws {
    let env = try pipelineEnv()
    let span = DateInterval(start: date(2026, 11, 20, 9), end: date(2026, 11, 20, 11))
    let key = PeriodKey.key(.hour, for: span.start, calendar: paris)
    try insertActivity(env.db, app: "Notes", from: date(2026, 11, 20, 9, 10), seconds: 200)
    _ = try SnapshotStore(env.db).insert(Snapshot(capturedAt: date(2026, 11, 20, 10, 5), app: "Notes",
                                                  text: "Quiet morning notes", contentHash: "q", source: .ax))
    let jobs = JobStore(env.db)
    let ledgerKeys = [9, 10, 11].map { PeriodKey.key(.hour, for: date(2026, 11, 20, $0), calendar: paris) }
    for (i, k) in ledgerKeys.enumerated() {
        let start = date(2026, 11, 20, 9 + i)
        try jobs.enqueue([JobSpec(kind: .timeLedger, periodKey: k, periodStart: start,
                                  periodEnd: start.addingTimeInterval(3_600), notBefore: start)], now: start)
        let id = try #require(try jobs.job(kind: .timeLedger, periodKey: k)?.id)
        try jobs.complete(id: id, status: .done, now: start)
    }
    _ = try await env.pipeline.run(try hourJob(env.db, span: span, key: key), context: hourContext())
    #expect(try jobs.status(kind: .timeLedger, periodKey: ledgerKeys[0]) == .pending)
    #expect(try jobs.status(kind: .timeLedger, periodKey: ledgerKeys[1]) == .pending)
    #expect(try jobs.status(kind: .timeLedger, periodKey: ledgerKeys[2]) == .done)
    #expect(try ChronicleStore(env.db).chronicle(.hour, key: key)?.metadata.mergedHours == 2)
}

@Test func emptyHourIsSkipped() async throws {
    let env = try pipelineEnv()
    try insertActivity(env.db, app: "Notes", from: date(2026, 11, 20, 14, 10), seconds: 30)
    let outcome = try await env.pipeline.run(try hourJob(env.db), context: hourContext())
    #expect(outcome == .skipped("empty"))
    #expect(env.fake.requests.isEmpty)
    #expect(try ChronicleStore(env.db).chronicle(.hour, key: hourKey) == nil)
}

@Test func focusOnlyHourIsSummarisedWithoutCallB() async throws {
    let env = try pipelineEnv()
    try insertActivity(env.db, app: "Zoom", from: date(2026, 11, 20, 14, 10), seconds: 1_800)
    #expect(try await env.pipeline.run(try hourJob(env.db), context: hourContext()) == .done)
    #expect(env.fake.requests.map(schemaName) == ["hour_chronicle"])
    let c = try #require(try ChronicleStore(env.db).chronicle(.hour, key: hourKey))
    #expect(c.metadata.entitiesDone && c.snapshotIDs.isEmpty && c.metadata.apps == ["Zoom"])
}

@Test func outputIsRedactedBeforeStorage() async throws {
    let leaky = """
        {"summary":"Paid the venue from FR76 3000 6000 0112 3456 7890 189 today.","projects":[{"name":"Oslo offsite",\
        "apps":["Mail"],"domains":[],"share":1}],"highlights":["IBAN FR76 3000 6000 0112 3456 7890 189 used"]}
        """
    let env = try pipelineEnv(.bySchema(["hour_chronicle": leaky, "hour_entities": hourEntitiesJSON]))
    try seedHour(env.db)
    _ = try await env.pipeline.run(try hourJob(env.db), context: hourContext())
    let c = try #require(try ChronicleStore(env.db).chronicle(.hour, key: hourKey))
    #expect(c.summary == "Paid the venue from [redacted] today.")
    #expect(c.metadata.highlights == ["IBAN [redacted] used"])
    #expect(!c.summary.contains("3000 6000"))
}

@Test func undecodableOutputThrowsInvalidOutputAndWritesNothing() async throws {
    let env = try pipelineEnv(.bySchema(["hour_chronicle": "{\"summary\": 12}", "hour_entities": hourEntitiesJSON]))
    try seedHour(env.db)
    await #expect(throws: MemoryError.invalidOutput(schema: "hour_chronicle")) {
        try await env.pipeline.run(try hourJob(env.db), context: hourContext())
    }
    #expect(try ChronicleStore(env.db).chronicle(.hour, key: hourKey) == nil)
    // The scheduler stores the case name, never the output.
    #expect(MemoryScheduler.code(for: MemoryError.invalidOutput(schema: "hour_chronicle")) == "invalid_output")
}

@Test func outputCapsAreAppliedInCode() async throws {
    let words = Array(repeating: "word", count: 200).joined(separator: " ")
    let long = String(repeating: "n", count: 200)
    let projects = (0..<12).map { "{\"name\":\"P\($0)\(long)\",\"apps\":[\"\(long)\"],\"domains\":[\"\(long)\"],\"share\":2}" }
        .joined(separator: ",")
    let highlights = (0..<9).map { "\"h\($0)\"" }.joined(separator: ",")
    let big = "{\"summary\":\"\(words)\",\"projects\":[\(projects)],\"highlights\":[\(highlights)]}"
    let env = try pipelineEnv(.bySchema(["hour_chronicle": big, "hour_entities": hourEntitiesJSON]))
    try seedHour(env.db)
    _ = try await env.pipeline.run(try hourJob(env.db), context: hourContext())
    let c = try #require(try ChronicleStore(env.db).chronicle(.hour, key: hourKey))
    #expect(c.summary.split(separator: " ").count == 120)
    #expect(c.metadata.projects.count == 8 && c.metadata.projects.allSatisfy { $0.share == 1 })
    #expect(c.metadata.projects.allSatisfy { p in
        p.name.count == 80 && p.apps.allSatisfy { $0.count == 80 } && p.domains.allSatisfy { $0.count == 80 }
    })
    #expect(c.metadata.highlights.count == 5)
}

@Test func staleGenerationDiscardsTheResult() async throws {
    let env = try pipelineEnv()
    try seedHour(env.db)
    await #expect(throws: DataGeneration.Stale.self) {
        try await env.pipeline.run(try hourJob(env.db), context: hourContext(generation: 3))
    }
    #expect(try ChronicleStore(env.db).chronicle(.hour, key: hourKey) == nil)
}

@Test func memoryErrorIsCoded() {
    let e: any CodedError = MemoryError.invalidOutput(schema: "hour_entities")
    #expect(e.code == "invalid_output")
}

@Test func snapshotForgottenDuringCallAKeepsTheRowDirtyWithoutItsID() async throws {
    let box = Mutex<(AppDatabase?, Int64?)>((nil, nil))
    let usage = LLMUsage(inputTokens: 1_000, cachedInputTokens: 0, outputTokens: 100, reasoningTokens: 0)
    let fake = FakeLLMClient(backend: .siwc) { request in
        if schemaName(request) == "hour_chronicle" {
            // "Forget" a snapshot while the model call is in flight.
            let (db, id) = box.withLock { $0 }
            if let db, let id {
                try? db.writer.write { try $0.execute(sql: "DELETE FROM snapshots WHERE id = ?", arguments: [id]) }
            }
            return [.delta(hourChronicleJSON), .complete(usage)]
        }
        return [.delta(hourEntitiesJSON), .complete(usage)]
    }
    let env = try pipelineEnv(fake)
    let rows = try seedHour(env.db)
    let forgotten = try #require(rows[1].id)  // Mail
    box.withLock { $0 = (env.db, forgotten) }
    #expect(try await env.pipeline.run(try hourJob(env.db), context: hourContext()) == .done)
    let c = try #require(try ChronicleStore(env.db).chronicle(.hour, key: hourKey))
    #expect(c.isDirty)
    #expect(!c.snapshotIDs.contains(forgotten) && !c.snapshotIDs.isEmpty)
}

@Test func chronicleDeletedDuringCallAIsNotRecreated() async throws {
    let box = Mutex<AppDatabase?>(nil)
    let usage = LLMUsage(inputTokens: 1_000, cachedInputTokens: 0, outputTokens: 100, reasoningTokens: 0)
    let fake = FakeLLMClient(backend: .siwc) { request in
        if schemaName(request) == "hour_chronicle", let db = box.withLock({ $0 }) {
            try? db.writer.write { try $0.execute(sql: "DELETE FROM chronicle WHERE level = 'hour'") }
        }
        return [.delta(schemaName(request) == "hour_chronicle" ? hourChronicleJSON : hourEntitiesJSON), .complete(usage)]
    }
    let env = try pipelineEnv(fake)
    try seedHour(env.db)
    try await env.db.writer.write { d in
        _ = try ChronicleStore(env.db).upsert(Chronicle(level: .hour, periodKey: hourKey, periodStart: hourStart,
                                                        periodEnd: hourEnd, summary: "old", isDirty: true,
                                                        generatedAt: hourStart), in: d)
    }
    box.withLock { $0 = env.db }
    _ = try await env.pipeline.run(try hourJob(env.db), context: hourContext())
    #expect(try ChronicleStore(env.db).chronicle(.hour, key: hourKey) == nil)
}

@Test func chronicleDirtiedDuringCallAStaysDirty() async throws {
    let box = Mutex<AppDatabase?>(nil)
    let usage = LLMUsage(inputTokens: 1_000, cachedInputTokens: 0, outputTokens: 100, reasoningTokens: 0)
    let fake = FakeLLMClient(backend: .siwc) { request in
        if schemaName(request) == "hour_chronicle", let db = box.withLock({ $0 }) {
            // Another writer touches the row (e.g. a forget that re-dirties it) during the call.
            try? db.writer.write {
                try $0.execute(sql: "UPDATE chronicle SET is_dirty = 1, summary = 'edited' WHERE level = 'hour'")
            }
        }
        return [.delta(schemaName(request) == "hour_chronicle" ? hourChronicleJSON : hourEntitiesJSON), .complete(usage)]
    }
    let env = try pipelineEnv(fake)
    try seedHour(env.db)
    try await env.db.writer.write { d in
        _ = try ChronicleStore(env.db).upsert(Chronicle(level: .hour, periodKey: hourKey, periodStart: hourStart,
                                                        periodEnd: hourEnd, summary: "old", isDirty: true,
                                                        generatedAt: hourStart), in: d)
    }
    box.withLock { $0 = env.db }
    _ = try await env.pipeline.run(try hourJob(env.db), context: hourContext())
    let c = try #require(try ChronicleStore(env.db).chronicle(.hour, key: hourKey))
    #expect(c.isDirty && c.summary.hasPrefix("The user prepared"))
}

@Test func dirtyHourWithoutRemainingEvidenceIsDeleted() async throws {
    let env = try pipelineEnv()
    let store = ChronicleStore(env.db)
    let dayKey = PeriodKey.key(.day, for: hourStart, calendar: paris)
    let day = PeriodKey.interval(.day, containing: hourStart, calendar: paris)
    // Only an excluded app's snapshot is left, and 30 s of focus.
    _ = try SnapshotStore(env.db).insert(Snapshot(capturedAt: date(2026, 11, 20, 14, 5), app: "Slack", text: slackText,
                                                  contentHash: "s", source: .ax))
    try insertActivity(env.db, app: "Notes", from: date(2026, 11, 20, 14, 10), seconds: 30)
    try ExclusionStore(env.db).add("app:Slack")
    try await env.db.writer.write { d in
        _ = try store.upsert(Chronicle(level: .hour, periodKey: hourKey, periodStart: hourStart, periodEnd: hourEnd,
                                       summary: "Old summary quoting the forgotten thread", isDirty: true,
                                       generatedAt: hourStart), in: d)
        _ = try store.upsert(Chronicle(level: .day, periodKey: dayKey, periodStart: day.start, periodEnd: day.end,
                                       summary: "Day", generatedAt: hourEnd), in: d)
    }
    #expect(try await env.pipeline.run(try hourJob(env.db), context: hourContext()) == .done)
    #expect(env.fake.requests.isEmpty)
    #expect(try store.chronicle(.hour, key: hourKey) == nil)
    #expect(try store.chronicle(.day, key: dayKey)?.isDirty == true)
}

@Test func emptyHourDeletionIsGenerationChecked() async throws {
    let env = try pipelineEnv()
    try await env.db.writer.write { d in
        _ = try ChronicleStore(env.db).upsert(Chronicle(level: .hour, periodKey: hourKey, periodStart: hourStart,
                                                        periodEnd: hourEnd, summary: "old", isDirty: true,
                                                        generatedAt: hourStart), in: d)
    }
    await #expect(throws: DataGeneration.Stale.self) {
        try await env.pipeline.run(try hourJob(env.db), context: hourContext(generation: 4))
    }
    #expect(try ChronicleStore(env.db).chronicle(.hour, key: hourKey) != nil)
}
