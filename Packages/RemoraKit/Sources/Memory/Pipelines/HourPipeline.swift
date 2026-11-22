import Capture
import Foundation
import GRDB
import LLM
import Redaction
import Storage
import os

/// Runs an `hour` job (one span of one or more merged hours): call A writes the hour chronicle,
/// call B extracts entities, facts and flags into the wiki and the salient flags.
///
/// - Call A runs when the span has no chronicle yet, or its chronicle is dirty; its write clears
///   `is_dirty` (F-2/F-20). Call B runs while `metadata.entitiesDone` is false, independently of
///   A, so a retry after a failed B never repeats A.
/// - Both calls share the same instructions and the same first input item (the evidence block),
///   so the second call reuses the cached prefix.
/// - Evidence is built under the exclusions as they stand now (`.denyAll` when they cannot be
///   loaded). Output is redacted before storage. Every write goes through
///   `DataGeneration.write(expected: context.generation)`, so a delete-all during the model call
///   discards the result.
public struct HourPipeline: JobRunner {
    /// Nothing to summarise: no snapshot and less focus than this.
    public static let minFocusSeconds: TimeInterval = 60
    /// Apps kept in `metadata.apps`.
    public static let maxApps = 5
    /// Slugs kept in `metadata.entities`.
    public static let maxChronicleEntities = 10
    /// Call B's `<existing>`: known pages named in the evidence, and their newest valid facts.
    public static let maxKnownPages = 60
    public static let maxKnownFactsPerPage = 8

    private let db: AppDatabase
    private let llm: LLMService
    private let calendar: Calendar
    private let redactor: Redactor
    private static let log = Logger(subsystem: "dev.remora", category: "memory")

    public init(db: AppDatabase, llm: LLMService, calendar: Calendar, redactor: Redactor = .init()) {
        self.db = db; self.llm = llm; self.calendar = calendar; self.redactor = redactor
    }

    public func run(_ job: Job, context: JobContext) async throws -> JobOutcome {
        guard job.kind == .hour, let start = job.periodStart, let end = job.periodEnd, end > start else {
            return .skipped("no_period")
        }
        let span = DateInterval(start: start, end: end)
        let store = ChronicleStore(db)
        let existing = try store.chronicle(.hour, key: job.periodKey)
        let needA = existing.map(\.isDirty) ?? true
        let needB = !(existing?.metadata.entitiesDone ?? false)
        guard needA || needB else { return .done }

        let policy = SnapshotPolicy.current(db)
        let evidence = try HourEvidence.build(db: db, span: span, policy: policy)
        if needA, evidence.items.isEmpty, evidence.focusSeconds < Self.minFocusSeconds {
            guard existing != nil else { return .skipped("empty") }
            // A dirty hour whose evidence is all gone (forgotten, excluded since, or below the focus
            // threshold): its old summary must not survive.
            try deleteChronicle(key: job.periodKey, span: span, context: context)
            return .done
        }

        let instructions = PipelinePrompt.instructions(.extractor, language: context.language, now: context.now,
                                                       calendar: calendar)
        let block = PipelinePrompt.evidenceBlock(evidence, calendar: calendar)

        if needA {
            let result = try await llm.complete(.hourChronicle, instructions: instructions,
                                                input: [.user(block), .user(PipelinePrompt.hourChronicleTask)],
                                                format: HourChronicleOutput.format, cloudAllowed: context.cloudAllowed)
            let output = try HourChronicleOutput.decode(result.text)
            try writeChronicle(output, job: job, span: span, evidence: evidence, existing: existing,
                               callID: result.callID, context: context)
        }

        var report: EntityReport?
        if needB {
            if evidence.items.isEmpty {
                // Focus time only: nothing to extract entities from.
                report = try writeEntities(nil, evidence: evidence, callID: nil, key: job.periodKey, context: context)
            } else {
                let known = try existingBlock(for: evidence, policy: policy)
                let result = try await llm.complete(.entityExtraction, instructions: instructions,
                                                    input: [.user(block), .user(known + "\n\n" + PipelinePrompt.hourEntitiesTask)],
                                                    format: HourEntitiesOutput.format, cloudAllowed: context.cloudAllowed)
                let output = try HourEntitiesOutput.decode(result.text)
                report = try writeEntities(output, evidence: evidence, callID: result.callID, key: job.periodKey,
                                           context: context)
            }
        }
        Self.log.info("hour \(job.periodKey, privacy: .public): \(evidence.items.count, privacy: .public) items, \(Int(evidence.focusSeconds), privacy: .public) s focus, A \(needA, privacy: .public), B \(needB, privacy: .public)")
        if let r = report {
            Self.log.info("hour \(job.periodKey, privacy: .public) entities: pages +\(r.pagesCreated, privacy: .public) ~\(r.pagesUpdated, privacy: .public) -\(r.entitiesDropped, privacy: .public), facts +\(r.factsAdded, privacy: .public) =\(r.factsConfirmed, privacy: .public) x\(r.factsInvalidated, privacy: .public) -\(r.factsDropped, privacy: .public), flags +\(r.flagsAdded, privacy: .public) =\(r.flagsMerged, privacy: .public) -\(r.flagsDropped, privacy: .public)")
        }
        return .done
    }

    // MARK: - Writes

    /// Writes call A's result. The row read before the call (`existing`) is compared with the row
    /// inside the transaction, so a change made during the model call is never lost:
    /// - a row deleted meanwhile is not recreated (nothing is written);
    /// - evidence snapshots deleted meanwhile are left out of `snapshot_ids`, and the row stays
    ///   dirty (its summary may still describe them), as does a row changed and dirtied meanwhile;
    ///   the planner requeues the hour, which then summarises what is left.
    private func writeChronicle(_ raw: HourChronicleOutput, job: Job, span: DateInterval, evidence: HourEvidence,
                                existing: Chronicle?, callID: Int64, context: JobContext) throws {
        let output = capped(raw)
        let hours = PeriodKey.closedHours(from: span.start, to: span.end, calendar: calendar)
        var apps: [String] = []
        for t in evidence.activity where !apps.contains(t.app) && apps.count < Self.maxApps { apps.append(t.app) }
        apps = apps.map(Self.cappedName)
        let store = ChronicleStore(db), jobs = JobStore(db), calls = LLMCallStore(db)
        let call = callID > 0 ? callID : nil
        let evidenceIDs = evidence.items.map(\.snapshotID)

        try DataGeneration.write(db, expected: context.generation) { d in
            let previous = try store.chronicle(.hour, key: job.periodKey, in: d)
            if existing != nil, previous == nil { return }
            let surviving = try Self.existingSnapshotIDs(evidenceIDs, in: d)
            let changedMeanwhile = previous != existing && previous?.isDirty == true
            let metadata = Chronicle.Metadata(
                projects: output.projects, highlights: output.highlights, apps: apps,
                entities: previous?.metadata.entities ?? [], mergedHours: max(hours.count, 1),
                entitiesDone: previous?.metadata.entitiesDone ?? false)
            let row = try store.upsert(Chronicle(
                level: .hour, periodKey: job.periodKey, periodStart: span.start, periodEnd: span.end,
                summary: output.summary, metadata: metadata, snapshotIDs: evidenceIDs.filter(surviving.contains),
                isDirty: surviving.count < Set(evidenceIDs).count || changedMeanwhile,
                generatedAt: context.now, llmCallID: call), in: d)
            if let call { try calls.setArtifact(callID: call, table: "chronicle", id: row.id, in: d) }
            try ChronicleParents.touch(.hour, start: span.start, db: db, calendar: calendar, now: context.now, in: d)
            for hour in hours {
                try jobs.requeue(kind: .timeLedger, periodKey: PeriodKey.key(.hour, for: hour.start, calendar: calendar),
                                 now: context.now, in: d)
            }
        }
    }

    /// The ids among `ids` whose snapshot still exists.
    private static func existingSnapshotIDs(_ ids: [Int64], in d: Database) throws -> Set<Int64> {
        guard !ids.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        return Set(try Int64.fetchAll(d, sql: "SELECT id FROM snapshots WHERE id IN (\(marks))",
                                      arguments: StatementArguments(ids)))
    }

    /// Removes the span's chronicle and touches its day (the day summary may quote it).
    private func deleteChronicle(key: String, span: DateInterval, context: JobContext) throws {
        let store = ChronicleStore(db)
        try DataGeneration.write(db, expected: context.generation) { d in
            try store.delete(.hour, key: key, in: d)
            try ChronicleParents.touch(.hour, start: span.start, db: db, calendar: calendar, now: context.now, in: d)
        }
    }

    /// Call B's `<existing>` section, read before the call (the applier re-resolves everything
    /// inside its write, so a page changed meanwhile is never overwritten from this snapshot).
    /// Filtered under the run's `policy`, inside the read.
    private func existingBlock(for evidence: HourEvidence, policy: CapturePolicy) throws -> String {
        try db.reader.read { d in
            try PipelinePrompt.existingBlock(for: evidence, maxPages: Self.maxKnownPages,
                                             maxFactsPerPage: Self.maxKnownFactsPerPage, policy: policy, in: d)
        }
    }

    /// Applies call B's output (`EntityApplier`: pages, facts, flags) and marks call B done on the
    /// span's chronicle with its top slugs, in one generation-checked transaction. A chronicle
    /// deleted during the call (the hour was forgotten) gets nothing.
    private func writeEntities(_ output: HourEntitiesOutput?, evidence: HourEvidence, callID: Int64?, key: String,
                               context: JobContext) throws -> EntityReport? {
        let store = ChronicleStore(db), calls = LLMCallStore(db)
        let call = callID.flatMap { $0 > 0 ? $0 : nil }
        return try DataGeneration.write(db, expected: context.generation) { d -> EntityReport? in
            guard var row = try store.chronicle(.hour, key: key, in: d) else { return nil }
            let report = try output.map {
                try EntityApplier.apply($0, evidence: evidence, periodKey: key, callID: call, at: context.now,
                                        calendar: calendar, redactor: redactor, in: d)
            }
            if let report { row.metadata.entities = Array(report.slugs.prefix(Self.maxChronicleEntities)) }
            row.metadata.entitiesDone = true
            try store.upsert(row, in: d)
            if let call { try calls.setArtifact(callID: call, table: "wiki_pages", id: nil, in: d) }
            return report
        }
    }

    /// Redaction of every model string (defence in depth), then the plan caps, enforced in code
    /// (F-50). Redacting first means a cut can never split a secret into an unrecognisable part.
    private func capped(_ o: HourChronicleOutput) -> CappedChronicle {
        let summary = redactor.redact(o.summary).split(whereSeparator: \.isWhitespace)
            .prefix(HourChronicleOutput.maxSummaryWords).joined(separator: " ")
        let projects = o.projects.prefix(HourChronicleOutput.maxProjects).map { p in
            ProjectShare(name: Self.cappedName(redactor.redact(p.name)),
                         apps: p.apps.prefix(HourChronicleOutput.maxNamesPerProject).map { Self.cappedName(redactor.redact($0)) },
                         domains: p.domains.prefix(HourChronicleOutput.maxNamesPerProject).map { Self.cappedName(redactor.redact($0)) },
                         share: p.share.isFinite ? min(max(p.share, 0), 1) : 0)
        }
        let highlights = o.highlights.prefix(HourChronicleOutput.maxHighlights).map {
            String(redactor.redact($0).prefix(HourChronicleOutput.maxHighlightChars))
        }
        return CappedChronicle(summary: summary, projects: projects, highlights: highlights)
    }

    /// Project, app and domain names in chronicle metadata: at most `maxNameChars`, after redaction.
    static func cappedName(_ s: String) -> String { String(s.prefix(HourChronicleOutput.maxNameChars)) }

    private struct CappedChronicle {
        var summary: String
        var projects: [ProjectShare]
        var highlights: [String]
    }
}
