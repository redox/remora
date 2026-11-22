import Capture
import Foundation
import GRDB
import LLM
import Redaction
import Retrieval
import Storage
import os

/// The newest snapshots since the working-memory watermark, as the model sees them (F-14).
public struct WorkingMemoryEvidence: Sendable, Equatable {
    /// Newest first; `index` 1 is the newest.
    public var items: [EvidenceItem]
    /// The newest `captured_at` of every snapshot after `since`, allowed or not: the next
    /// watermark, so excluded snapshots are not reconsidered on every run.
    public var newestCapturedAt: Date?

    /// Snapshots fetched at most (newest first) before the policy filter and the budget.
    static let maxFetched = 200
    /// Each snapshot is cut to this many characters first; when the budget is short, a snapshot
    /// keeps at least `minShare`, so at most `maxChars / minShare` (the newest) are kept.
    static let perItem = 1_500
    static let minShare = 300

    /// Snapshots captured (or rolled) after `since`, allowed by `policy`, deduped by content hash,
    /// newest first, fitted to `maxChars` of text with the same item and policy code as
    /// `HourEvidence` (only the newest that fit are kept: no spreading over older ones).
    public static func build(db: AppDatabase, since: Date, policy: CapturePolicy,
                             maxChars: Int) throws -> WorkingMemoryEvidence {
        let (snapshots, newest) = try db.reader.read { d in
            (try Snapshot.fetchAll(d, sql: """
                SELECT * FROM snapshots WHERE captured_at > ? ORDER BY captured_at DESC, id DESC LIMIT ?
                """, arguments: [since, maxFetched]),
             try Date.fetchOne(d, sql: "SELECT MAX(captured_at) FROM snapshots WHERE captured_at > ?", arguments: [since]))
        }
        let allowed = HourEvidence.allowed(snapshots, policy: policy)
            .prefix(max(1, maxChars / minShare))
        let items = HourEvidence.items(Array(allowed), maxChars: maxChars, perItem: perItem, minShare: minShare)
        return WorkingMemoryEvidence(items: items, newestCapturedAt: newest)
    }
}

/// Runs a `working_memory` job: one small-tier call refreshes what the user is dealing with right
/// now from the snapshots since `memory.wm.lastSnapshotAt` and the current items.
///
/// - Routing (F-17/F-30/F-40): job `workingMemory` (small, `gpt-6-luna`) with
///   `cloudAllowed: context.cloudAllowed`. When the cloud is denied the router uses on-device only;
///   that path gets a smaller prompt (≤ 3,500 chars of evidence, ≤ 10 current items, F-31), and
///   an unavailable on-device model gives `.skipped("on_device_unavailable")`.
/// - Only items that cite at least one valid snapshot are merged (`WorkingMemoryStore.merge`):
///   an item the model repeats without new evidence is not refreshed, so it keeps decaying.
/// - The merge, the call's artifact and the watermark advance are one generation-checked write.
public struct WorkingMemoryPipeline: JobRunner {
    public static let cloudMaxChars = 6_000
    public static let onDeviceMaxChars = 3_500
    public static let onDeviceMaxItems = 10
    /// Evidence never reaches back further than items live.
    static let maxLookback = WorkingMemoryStore.maxAge

    private let db: AppDatabase
    private let llm: LLMService
    private let calendar: Calendar
    private let redactor: Redactor
    private static let log = Logger(subsystem: "dev.remora", category: "memory")

    public init(db: AppDatabase, llm: LLMService, calendar: Calendar, redactor: Redactor = .init()) {
        self.db = db; self.llm = llm; self.calendar = calendar; self.redactor = redactor
    }

    public func run(_ job: Job, context: JobContext) async throws -> JobOutcome {
        guard job.kind == .workingMemory else { return .skipped("wrong_kind") }
        let now = context.now
        let floor = now.addingTimeInterval(-Self.maxLookback)
        let last = try SettingsStore(db).value(Date.self, forKey: JobPlanner.workingMemorySnapshotKey)
        let since = max(last ?? floor, floor)
        let maxChars = context.cloudAllowed ? Self.cloudMaxChars : Self.onDeviceMaxChars
        let maxItems = context.cloudAllowed ? WorkingMemoryStore.maxItems : Self.onDeviceMaxItems

        let policy = SnapshotPolicy.current(db)
        let evidence = try WorkingMemoryEvidence.build(db: db, since: since, policy: policy, maxChars: maxChars)
        guard !evidence.items.isEmpty else {
            if let newest = evidence.newestCapturedAt { try advance(to: newest, context: context) }
            return .skipped("no_evidence")
        }
        let current = Array(try allowedItems(now: now, policy: policy).prefix(maxItems))
        let block = PipelinePrompt.evidenceBlock(HourEvidence(span: DateInterval(start: min(since, now), end: now),
                                                              items: evidence.items, activity: []),
                                                 calendar: calendar)
        let task = PipelinePrompt.workingMemoryBlock(current, now: now) + "\n\n"
            + PipelinePrompt.workingMemoryTask(maxItems: maxItems)
        let result: LLMResult
        do {
            result = try await llm.complete(.workingMemory, instructions: PipelinePrompt.instructions(
                .extractor, language: context.language, now: now, calendar: calendar),
                                            input: [.user(block), .user(task)], format: WorkingMemoryOutput.format,
                                            cloudAllowed: context.cloudAllowed)
        } catch LLMError.onDeviceUnavailable {
            Self.log.info("working memory \(job.periodKey, privacy: .public): on-device unavailable, skipped")
            return .skipped("on_device_unavailable")
        }
        let output = try WorkingMemoryOutput.decode(result.text)
        let call = result.callID > 0 ? result.callID : nil
        let items = self.items(output, evidence: evidence, maxItems: maxItems, callID: call, now: now)
        let store = WorkingMemoryStore(db), calls = LLMCallStore(db)
        try DataGeneration.write(db, expected: context.generation) { d in
            try store.merge(items, now: now, in: d)
            if let call { try calls.setArtifact(callID: call, table: "working_memory", id: nil, in: d) }
            if let newest = evidence.newestCapturedAt { try advance(to: newest, in: d) }
        }
        Self.log.info("working memory \(job.periodKey, privacy: .public): \(evidence.items.count, privacy: .public) snapshots, \(output.items.count, privacy: .public) items out, \(items.count, privacy: .public) merged, \(result.route.backend.rawValue, privacy: .public)")
        return .done
    }

    /// The current items by decayed relevance, without those whose snapshots are now all excluded
    /// (or gone): an item learned from an app excluded since never reaches the prompt. Items
    /// with no snapshot ids are kept. They stay stored and decay as usual. The rewrite context
    /// uses the same rule (`DerivedPolicy.requiringLiveEvidence`).
    private func allowedItems(now: Date, policy: CapturePolicy) throws -> [WorkingMemoryItem] {
        let store = WorkingMemoryStore(db)
        return try db.reader.read { d in
            try DerivedPolicy.requiringLiveEvidence(try store.top(WorkingMemoryStore.maxItems, now: now, in: d),
                                                    ids: \.snapshotIDs, policy: policy, in: d)
        }
    }

    /// The model's items that cite evidence, redacted and capped: at most `maxItems`, text at most
    /// `maxWorkingMemoryTextChars`, relevance clamped by the store.
    private func items(_ o: WorkingMemoryOutput, evidence: WorkingMemoryEvidence, maxItems: Int, callID: Int64?,
                       now: Date) -> [WorkingMemoryItem] {
        var out: [WorkingMemoryItem] = []
        for item in o.items where out.count < maxItems {
            let ids = evidence.items.snapshotIDs(for: item.evidence)
            let text = String(redactor.redact(item.text).split(whereSeparator: { $0.isNewline }).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces).prefix(PipelinePrompt.maxWorkingMemoryTextChars))
            guard !ids.isEmpty, !TextFold.key(text).isEmpty else { continue }
            out.append(WorkingMemoryItem(text: text, kind: item.kind.rawValue, normKey: TextFold.key(text),
                                         relevance: item.relevance, snapshotIDs: ids, addedAt: now, lastSeenAt: now,
                                         llmCallID: callID))
        }
        return out
    }

    private func advance(to newest: Date, context: JobContext) throws {
        try DataGeneration.write(db, expected: context.generation) { d in try advance(to: newest, in: d) }
    }

    /// Moves `memory.wm.lastSnapshotAt` forward to `newest` (never back; an unreadable value is
    /// replaced).
    private func advance(to newest: Date, in d: Database) throws {
        let settings = SettingsStore(db)
        let key = JobPlanner.workingMemorySnapshotKey
        if let stored = try? settings.value(Date.self, forKey: key, in: d), stored >= newest { return }
        try settings.setValue(newest, forKey: key, in: d)
    }
}
