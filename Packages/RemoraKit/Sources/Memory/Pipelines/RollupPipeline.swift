import Capture
import Foundation
import GRDB
import LLM
import Redaction
import Retrieval
import Storage
import os

/// Runs `day_rollup`, `week_rollup`, `month_rollup` and `year_rollup` jobs (large tier): one
/// call summarises the period from its children (hour chronicles for a day, day chronicles for a
/// week or month, month chronicles for a year).
///
/// - Children are the chronicles one level down whose period lies inside the job's period; days
///   or hours without a chronicle (idle, skipped) are simply absent (F-10). No children (before
///   the call, or all deleted during it): an existing row is deleted (it describes forgotten
///   content) and its parents touched; with no row, `.skipped("no_children")`.
/// - A row that exists and is not dirty is up to date: no call.
/// - Provenance: a **day** stores the union of its hours' `snapshot_ids`; a week, month or year
///   stores `snapshot_ids = []`, and its provenance is the `child_ids` chain down to the days
///   (this keeps long periods from carrying every snapshot id of the period).
/// - The write stores `child_ids`, the call and `is_dirty = 0`, then touches every parent
///   (`ChronicleParents.touch`: `ChronicleLevel.parents`, a day → its week and its month, a month
///   → its year, F-1). The row stays dirty when a child was rewritten, added or deleted while the
///   model was writing (F-2): the planner requeues it.
/// - Children citing only snapshots excluded now are left out (`DerivedPolicy`); none left: no call.
/// - Focus time and time per project are filtered by the exclusions as they stand now (F-58).
///   Output is redacted, then capped. Every write goes through `DataGeneration.write(expected:)`.
public struct RollupPipeline: JobRunner {
    /// Projects kept in the rollup's metadata.
    public static let maxProjects = 8
    public static let maxHighlights = 5
    public static let maxHighlightChars = 200

    /// Summary word cap per level (plan 4 output caps).
    public static func maxWords(_ level: ChronicleLevel) -> Int {
        switch level {
        case .hour: HourChronicleOutput.maxSummaryWords
        case .day: 250
        case .week: 300
        case .month: 400
        case .year: 500
        }
    }

    private let db: AppDatabase
    private let llm: LLMService
    private let calendar: Calendar
    private let redactor: Redactor
    private static let log = Logger(subsystem: "dev.remora", category: "memory")

    public init(db: AppDatabase, llm: LLMService, calendar: Calendar, redactor: Redactor = .init()) {
        self.db = db; self.llm = llm; self.calendar = calendar; self.redactor = redactor
    }

    public func run(_ job: Job, context: JobContext) async throws -> JobOutcome {
        guard let level = ChronicleLevel.allCases.first(where: { $0.jobKind == job.kind }),
              let childLevel = level.childLevel else { return .skipped("wrong_kind") }
        guard let start = job.periodStart, let end = job.periodEnd, end > start else { return .skipped("no_period") }
        let period = DateInterval(start: start, end: end)
        let store = ChronicleStore(db)
        let policy = SnapshotPolicy.current(db)
        let (existing, all, children) = try await db.reader.read { d in
            let all = try store.chronicles(childLevel, within: period, in: d)
            return (try store.chronicle(level, key: job.periodKey, in: d), all,
                    try DerivedPolicy.filter(all, ids: \.snapshotIDs, policy: policy, in: d))
        }
        if all.isEmpty {
            guard existing != nil else { return .skipped("no_children") }
            try deleteRollup(level, key: job.periodKey, period: period, childLevel: childLevel, context: context)
            Self.log.info("\(level.rawValue, privacy: .public) \(job.periodKey, privacy: .public): no children, row deleted")
            return .done
        }
        if let existing, !existing.isDirty { return .done }
        // Children citing only snapshots excluded now never reach the prompt; none left: no call.
        guard !children.isEmpty else { return .skipped("no_allowed_children") }

        let activity = HourEvidence.activity(try ActivityStore(db).focusTotals(in: period), policy: policy)
        let ledgerStore = TimeLedgerStore(db)
        let (ledger, ledgerRows) = try await db.reader.read { d in
            (try ledgerStore.report(from: period.start, to: period.end, in: d),
             try ledgerStore.rows(from: period.start, to: period.end, in: d))
        }
        let projects = Self.projectTime(ledgerRows, policy: policy)
        let block = PipelinePrompt.rollupBlock(level: level, key: job.periodKey, period: period, children: children,
                                               projects: projects, activity: activity, calendar: calendar)
        let task = PipelinePrompt.rollupTask(level, maxWords: Self.maxWords(level), maxHighlights: Self.maxHighlights)
        let result = try await llm.complete(level.jobType, instructions: PipelinePrompt.instructions(
            .summarizer, language: context.language, now: context.now, calendar: calendar),
                                            input: [.user(block), .user(task)], format: RollupOutput.format,
                                            cloudAllowed: context.cloudAllowed)
        let output = capped(try RollupOutput.decode(result.text), level: level)
        let shares = Self.shares(output.projects, ledger: ledger)
        let dirty = try write(output, shares: shares, level: level, key: job.periodKey, period: period,
                              childLevel: childLevel, existing: existing, children: children, policy: policy,
                              callID: result.callID, context: context)
        Self.log.info("\(level.rawValue, privacy: .public) \(job.periodKey, privacy: .public): \(children.count, privacy: .public) children, dirty \(dirty, privacy: .public)")
        return .done
    }

    /// Time per project for the prompt, from ledger rows whose (app, domain) `policy` still
    /// allows (F-58: an excluded app's time, and a project only it fed, never reach the model),
    /// without `Unassigned` (unless `includeUnassigned`), most first (ties by name). Shared with
    /// the chat's `time_report` and the evening wrap (Plan 5).
    public static func projectTime(_ rows: [TimeLedgerRow], policy: CapturePolicy,
                                   includeUnassigned: Bool = false) -> [(name: String, seconds: Double)] {
        var seconds: [String: Double] = [:]
        for r in rows where (includeUnassigned || r.project != TimeLedgerBuilder.unassigned) && r.seconds > 0
            && SnapshotPolicy.allows(app: r.app, domain: r.domain, policy: policy) {
            seconds[r.project, default: 0] += r.seconds
        }
        return seconds.map { (name: $0.key, seconds: $0.value) }
            .sorted { ($0.seconds, $1.name) > ($1.seconds, $0.name) }
    }

    // MARK: - Writes

    /// Writes the rollup and touches its parents, in one generation-checked transaction. The
    /// children are read again inside it: those deleted meanwhile are left out of `child_ids` and
    /// `snapshot_ids` (all of them deleted: the rollup is removed instead, as with no children),
    /// and a change to what the summary was built from (a child added or deleted, or its summary
    /// or snapshots rewritten; not a metadata-only update) or a row dirtied again meanwhile keeps
    /// `is_dirty`. A row deleted meanwhile is not recreated. Returns whether the row was left dirty.
    @discardableResult
    private func write(_ output: RollupOutput, shares: [ProjectShare], level: ChronicleLevel, key: String, period: DateInterval,
                       childLevel: ChronicleLevel, existing: Chronicle?, children: [Chronicle], policy: CapturePolicy,
                       callID: Int64, context: JobContext) throws -> Bool {
        let store = ChronicleStore(db), calls = LLMCallStore(db)
        let call = callID > 0 ? callID : nil
        let used = Set(children.compactMap(\.id))
        return try DataGeneration.write(db, expected: context.generation) { d -> Bool in
            let previous = try store.chronicle(level, key: key, in: d)
            if existing != nil, previous == nil { return false }
            // Filtered as `children` were, so an excluded child is no change.
            let current = try DerivedPolicy.filter(try store.chronicles(childLevel, within: period, in: d),
                                                   ids: \.snapshotIDs, policy: policy, in: d)
            let kept = current.filter { $0.id.map(used.contains) ?? false }
            if kept.isEmpty {
                try removeRollup(level, key: key, period: period, context: context, in: d)
                return false
            }
            let changedMeanwhile = current.map(Source.init) != children.map(Source.init)
                || (previous != existing && previous?.isDirty == true)
            let snapshots = level == .day ? Array(Set(kept.flatMap(\.snapshotIDs))).sorted() : []
            let metadata = Chronicle.Metadata(projects: shares, highlights: output.highlights)
            let row = try store.upsert(Chronicle(
                level: level, periodKey: key, periodStart: period.start, periodEnd: period.end,
                summary: output.summary, metadata: metadata, snapshotIDs: snapshots,
                childIDs: kept.compactMap(\.id), isDirty: changedMeanwhile, generatedAt: context.now,
                llmCallID: call), in: d)
            if let call { try calls.setArtifact(callID: call, table: "chronicle", id: row.id, in: d) }
            try ChronicleParents.touch(level, start: period.start, db: db, calendar: calendar, now: context.now, in: d)
            return changedMeanwhile
        }
    }

    /// What a rollup summary is built from, per child: the in-transaction re-check compares only
    /// this, so a metadata-only update of a child (hour call B's `entitiesDone`) is no change.
    private struct Source: Equatable {
        var id: Int64?
        var periodKey: String
        var summary: String
        var snapshotIDs: [Int64]
        init(_ c: Chronicle) { id = c.id; periodKey = c.periodKey; summary = c.summary; snapshotIDs = c.snapshotIDs }
    }

    /// Removes a rollup whose children are all gone (unless one appeared meanwhile).
    private func deleteRollup(_ level: ChronicleLevel, key: String, period: DateInterval, childLevel: ChronicleLevel,
                              context: JobContext) throws {
        let store = ChronicleStore(db)
        try DataGeneration.write(db, expected: context.generation) { d in
            guard try store.chronicles(childLevel, within: period, in: d).isEmpty else { return }
            try removeRollup(level, key: key, period: period, context: context, in: d)
        }
    }

    /// Deletes the rollup row if it exists and touches its parents (they may quote it).
    private func removeRollup(_ level: ChronicleLevel, key: String, period: DateInterval, context: JobContext,
                              in d: Database) throws {
        try ChronicleStore(db).delete(level, key: key, in: d)
        try ChronicleParents.touch(level, start: period.start, db: db, calendar: calendar, now: context.now, in: d)
    }

    /// The model's project names with their share of the period's ledger time, matched by
    /// `TextFold.key` (F-66); 0 for a name the ledger does not know.
    static func shares(_ names: [String], ledger: [(project: String, seconds: Double)]) -> [ProjectShare] {
        let total = ledger.reduce(0) { $0 + max($1.seconds, 0) }
        var seconds: [String: Double] = [:]
        for row in ledger { seconds[TextFold.key(row.project), default: 0] += max(row.seconds, 0) }
        return names.map { name in
            let s = seconds[TextFold.key(name)] ?? 0
            return ProjectShare(name: name, share: total > 0 ? min(s / total, 1) : 0)
        }
    }

    /// Redaction of every model string (defence in depth), then the caps, enforced in code (F-50).
    private func capped(_ o: RollupOutput, level: ChronicleLevel) -> RollupOutput {
        let summary = redactor.redact(o.summary).split(whereSeparator: \.isWhitespace)
            .prefix(Self.maxWords(level)).joined(separator: " ")
        var projects: [String] = []
        var keys = Set<String>()
        for p in o.projects {
            let name = HourPipeline.cappedName(redactor.redact(p).trimmingCharacters(in: .whitespacesAndNewlines))
            let key = TextFold.key(name)
            guard !key.isEmpty, projects.count < Self.maxProjects, keys.insert(key).inserted else { continue }
            projects.append(name)
        }
        let highlights = o.highlights.prefix(Self.maxHighlights).map {
            String(redactor.redact($0).prefix(Self.maxHighlightChars))
        }
        return RollupOutput(summary: summary, projects: projects, highlights: Array(highlights))
    }
}

extension ChronicleLevel {
    /// The LLM job type of this level's chronicle.
    var jobType: JobType {
        switch self {
        case .hour: .hourChronicle
        case .day: .dayRollup
        case .week: .weekRollup
        case .month: .monthRollup
        case .year: .yearRollup
        }
    }
}
