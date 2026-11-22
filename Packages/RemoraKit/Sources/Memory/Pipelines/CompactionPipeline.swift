import Capture
import Embeddings
import Foundation
import GRDB
import LLM
import Redaction
import Retrieval
import Storage
import os

/// What one compaction did: counts, flags and step names only, never content. Saved as
/// `memory.compaction.last` for Settings › Memory.
public struct CompactionReport: Codable, Sendable, Equatable {
    public var startedAt: Date
    public var finishedAt: Date
    public var rerollsQueued = 0
    public var pagesPruned = 0
    public var loopsMerged = 0
    public var loopsClosed = 0
    public var loopsExpired = 0
    public var loopsChecked = 0
    public var styleRulesMerged = 0
    public var snapshotsDeleted = 0
    public var embeddingsWritten = 0
    public var boilerplateLearned = 0
    public var boilerplateForgotten = 0
    public var digestRebuilt = false
    public var vacuumed = false
    public var bytesBefore: Int64 = 0
    public var bytesAfter: Int64 = 0
    /// Steps that failed or did not run (the LLM steps when the cloud is denied), by name.
    public var skippedSteps: [String] = []

    public init(startedAt: Date, finishedAt: Date? = nil) {
        self.startedAt = startedAt; self.finishedAt = finishedAt ?? startedAt
    }
}

/// Runs the nightly `compaction` job. It always passes the scheduler gate (F-8): `context.cloudAllowed`
/// only decides whether its LLM steps (loop checks, digest) run; everything else always does.
///
/// Steps, in order. Each catches its own error, adds its name to `skippedSteps` and the run goes on,
/// except cancellation, which is checked between steps and inside the long loops and ends the run
/// (`run` rethrows it). Every data write goes through `DataGeneration.write(expected:
/// context.generation)` (F-12), so after a delete-all nothing is written.
/// 1. `requeue`: dirty day, week, month and year chronicles get their rollup job back (`done` or
///    `skipped` → pending; one is enqueued when the row has none). Hours are left to the planner.
///    `boilerplate_retention`: stats not seen within the retention window are deleted (not with
///    `.forever`). `boilerplate_excluded`: stats and learned lines of surfaces the current
///    exclusions deny are dropped (throwing exclusions read: on a load error nothing is dropped).
///    `boilerplate`: `BoilerplateStore.refresh` over every surface (prunes stats below one doc, F-25).
///    `jobs`: finished jobs last updated more than 30 days ago (the planner's horizon) are deleted,
///    except an hour job whose chronicle is dirty.
/// 2. `prune`: wiki pages with at most one mention, not seen for 30 days, no fact at all (valid or
///    not, F-62) and not named by an open flag (title or alias = its person or project, folded);
///    their vectors go too.
/// 3. `loop_merge`: open flags of the same kind, owner and person whose texts are ≥ 0.7 similar
///    (`TextFold.jaccard`) merge into the oldest (snapshot ids unioned). `loop_expire`: an open
///    todo or commitment unseen for 14 days, or an event 1 day past due, becomes `expired`, never
///    `done`. `loop_checks` (LLM): `LoopCheck` on the open user-owned commitments and todos checked
///    longest ago (never checked first), at most 10 model calls of job type `evidenceCheck` per
///    night (calls already made since the job's period start count); a loop closes only on a
///    verified quote (F-26). `style_merge`: model-owned style notes are deduplicated with
///    `StyleNotesMerge.merge`; the user's own notes are never rewritten.
/// 4. `digest` (LLM): `DigestPipeline.rebuild`, at most once a night (none when a digest was
///    created since the night's start). Skipped once a loop check hit the usage limit.
/// 5. `retention`: `RetentionStore` batches of 500 older than `now − n days`; `.forever` deletes
///    nothing. Never cascades (F-61); uncovered snapshots stay (F-36), except (`retention_excluded`)
///    uncovered, uncited ones whose app or site the current exclusions no longer allow: no hour job
///    will ever summarise them. The exclusions are read with a throwing read: if they cannot load,
///    that part deletes nothing (never `.denyAll`). Both paths leave tombstones
///    (`SnapshotTombstones`); `tombstones` then prunes those no derived row cites.
/// 6. `embeddings`: `EmbeddingIndexer.run` until nothing is pending, 2,000 are written, a round
///    makes no progress or 120 s have passed; with the embedder unavailable (or reporting no
///    dimension) only orphan vectors are dropped.
/// 7. `maintenance`: FTS `optimize` (one short transaction per table), `PRAGMA optimize`; `vacuum`
///    when `memory.lastVacuumAt` is 7 days old or more (outside any transaction); then
///    `PRAGMA wal_checkpoint(TRUNCATE)`.
///
/// A usage-limit error from an LLM step is kept: the remaining LLM steps are skipped, every other
/// step still runs, the report is saved, and then `run` rethrows it so the scheduler backs off.
public struct CompactionPipeline: JobRunner {
    public static let lastReportKey = "memory.compaction.last"
    public static let lastVacuumKey = "memory.lastVacuumAt"
    public static let vacuumEvery: TimeInterval = 7 * 86_400
    public static let pruneAfter: TimeInterval = 30 * 86_400
    public static let mergeSimilarity = 0.7
    public static let staleLoopAfter: TimeInterval = 14 * 86_400
    public static let eventGrace: TimeInterval = 86_400
    public static let maxLoopChecks = 10
    public static let maxEmbeddings = 2_000
    public static let embeddingBatch = 200
    public static let embeddingTimeBudget: Duration = .seconds(120)
    static let maxEmbeddingRounds = 50
    static let maxRetentionRounds = 400
    static let ftsTables = ["snapshots_fts", "chronicle_fts", "wiki_pages_fts", "wiki_facts_fts"]

    private let db: AppDatabase
    private let dbURL: URL?
    private let embedder: any Embedder
    private let digest: DigestPipeline
    private let calendar: Calendar
    private let loopCheck: LoopCheck
    private static let log = Logger(subsystem: "dev.remora", category: "memory")

    public init(db: AppDatabase, dbURL: URL?, llm: LLMService, embedder: any Embedder, digest: DigestPipeline,
                calendar: Calendar, redactor: Redactor = .init()) {
        self.db = db; self.dbURL = dbURL; self.embedder = embedder; self.digest = digest; self.calendar = calendar
        loopCheck = LoopCheck(db: db, llm: llm, calendar: calendar, redactor: redactor)
    }

    /// Runs every step; rethrows a cancellation, and a usage limit after the report is saved.
    public func run(_ job: Job, context: JobContext) async throws -> JobOutcome {
        guard job.kind == .compaction else { return .skipped("wrong_kind") }
        let (_, limit) = try await execute(context: context, night: job.periodStart)
        if let limit { throw limit }
        return .done
    }

    /// Runs every step and saves the report (see the type comment). Throws only `CancellationError`;
    /// a usage limit is recorded in `skippedSteps`. The night starts at the local midnight of `now`.
    @discardableResult
    public func compact(context: JobContext) async throws -> CompactionReport {
        try await execute(context: context, night: nil).report
    }

    /// The run, and the usage-limit error an LLM step hit (nil if none). `night` is when this
    /// night's loop-check calls started counting (the job's period start).
    func execute(context: JobContext, night: Date?) async throws -> (report: CompactionReport, limit: (any Error)?) {
        let clock = ContinuousClock(), started = clock.now
        let now = context.now
        let nightStart = night ?? calendar.startOfDay(for: now)
        var report = CompactionReport(startedAt: now)
        var limit: (any Error)?
        report.bytesBefore = fileBytes()
        /// Records a failed step; cancellation ends the run instead.
        func failed(_ step: String, _ error: any Error) throws {
            if Self.isCancellation(error) { throw CancellationError() }
            report.skippedSteps.append(step)
            Self.log.error("compaction step \(step, privacy: .public) failed: \(Self.code(error), privacy: .public)")
        }
        func write<T>(_ body: (Database) throws -> T) throws -> T {
            try DataGeneration.write(db, expected: context.generation, body)
        }

        // 1. Dirty rollups and interface clutter.
        try Task.checkCancellation()
        do { report.rerollsQueued = try write { try requeueDirtyRollups(now: now, in: $0) } } catch { try failed("requeue", error) }
        do {
            if let cutoff = try retentionCutoff(now: now) {
                _ = try write { try BoilerplateStore.pruneStats(lastSeenBefore: cutoff, in: $0) }
            }
        } catch { try failed("boilerplate_retention", error) }
        do { try dropExcludedBoilerplate(context: context) } catch { try failed("boilerplate_excluded", error) }
        do {
            let (learned, forgotten) = try write { try BoilerplateStore.refresh(surface: nil, at: now, in: $0) }
            report.boilerplateLearned = learned
            report.boilerplateForgotten = forgotten
        } catch { try failed("boilerplate", error) }
        do { _ = try write { try JobStore.pruneFinished(before: now.addingTimeInterval(-JobPlanner.horizon), in: $0) } } catch {
            try failed("jobs", error)
        }

        // 2. Stale wiki pages.
        try Task.checkCancellation()
        do { report.pagesPruned = try write { try Self.pruneStalePages(now: now, in: $0) } } catch { try failed("prune", error) }

        // 3. Open loops and style notes.
        try Task.checkCancellation()
        do { report.loopsMerged = try write { try Self.mergeLoops(in: $0) } } catch { try failed("loop_merge", error) }
        do { report.loopsExpired = try write { try Self.expireLoops(now: now, in: $0) } } catch { try failed("loop_expire", error) }
        if context.cloudAllowed {
            do { try await checkLoops(context: context, since: nightStart, report: &report) } catch {
                try failed("loop_checks", error)
                if Self.isUsageLimit(error) { limit = error }
            }
        } else {
            report.skippedSteps.append("loop_checks")
        }
        try Task.checkCancellation()
        do { report.styleRulesMerged = try write { try mergeStyleNotes(in: $0) } } catch { try failed("style_merge", error) }

        // 4. Digest.
        try Task.checkCancellation()
        // A forget marked the digest dirty: rebuild even if tonight already has one.
        let digestDirty = ((try? DigestPipeline.dirtySince(db)) ?? nil) != nil
        if context.cloudAllowed, limit == nil, digestDirty || (try? digestBuilt(since: nightStart)) != true {
            do { report.digestRebuilt = try await digest.rebuild(context: context) != nil } catch {
                try failed("digest", error)
                if Self.isUsageLimit(error) { limit = error }
            }
        } else {
            report.skippedSteps.append("digest")
        }

        // 5. Retention.
        try Task.checkCancellation()
        do { try retention(context: context, report: &report) } catch { try failed("retention", error) }
        try Task.checkCancellation()
        do { try deleteUnsummarisable(context: context, report: &report) } catch { try failed("retention_excluded", error) }
        do { _ = try write { try SnapshotTombstones.pruneUncited(in: $0) } } catch { try failed("tombstones", error) }

        // 6. Embeddings.
        try Task.checkCancellation()
        do {
            let available = try await embed(context: context, report: &report)
            if !available { report.skippedSteps.append("embeddings") }
        } catch { try failed("embeddings", error) }

        // 7. Maintenance. FTS merges are not data: one short transaction per index, no generation check.
        try Task.checkCancellation()
        do {
            for fts in Self.ftsTables {
                try Task.checkCancellation()
                try await db.writer.write { try $0.execute(sql: "INSERT INTO \(fts)(\(fts)) VALUES('optimize')") }
            }
            try await db.writer.writeWithoutTransaction { try $0.execute(sql: "PRAGMA optimize") }
        } catch { try failed("maintenance", error) }
        try Task.checkCancellation()
        do {
            let last = (try? SettingsStore(db).value(Date.self, forKey: Self.lastVacuumKey)) ?? nil
            if last.map({ now.timeIntervalSince($0) >= Self.vacuumEvery }) ?? true {
                try await db.writer.writeWithoutTransaction { try $0.execute(sql: "VACUUM") }
                report.vacuumed = true
                try write { try SettingsStore(db).setValue(now, forKey: Self.lastVacuumKey, in: $0) }
            }
        } catch { try failed("vacuum", error) }
        do {
            try await db.writer.writeWithoutTransaction { try $0.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
        } catch { try failed("checkpoint", error) }

        report.bytesAfter = fileBytes()
        let elapsed = clock.now - started
        report.finishedAt = now.addingTimeInterval(Double(elapsed.components.seconds)
                                                   + Double(elapsed.components.attoseconds) / 1e18)
        do { try write { try SettingsStore(db).setValue(report, forKey: Self.lastReportKey, in: $0) } } catch {
            Self.log.error("compaction report not saved: \(Self.code(error), privacy: .public)")
        }
        Self.log.info("""
            compaction: rerolls \(report.rerollsQueued, privacy: .public), pages pruned \(report.pagesPruned, privacy: .public), \
            loops merged \(report.loopsMerged, privacy: .public) expired \(report.loopsExpired, privacy: .public) \
            checked \(report.loopsChecked, privacy: .public) closed \(report.loopsClosed, privacy: .public), \
            style merged \(report.styleRulesMerged, privacy: .public), digest \(report.digestRebuilt, privacy: .public), \
            snapshots deleted \(report.snapshotsDeleted, privacy: .public), vectors \(report.embeddingsWritten, privacy: .public), \
            boilerplate +\(report.boilerplateLearned, privacy: .public) -\(report.boilerplateForgotten, privacy: .public), \
            vacuumed \(report.vacuumed, privacy: .public), bytes \(report.bytesBefore, privacy: .public) → \(report.bytesAfter, privacy: .public), \
            skipped [\(report.skippedSteps.joined(separator: ","), privacy: .public)], usage limit \(limit != nil, privacy: .public)
            """)
        return (report, limit)
    }

    // MARK: - Steps

    /// Step 1: the rollup job of every dirty day, week, month and year chronicle back to pending
    /// (`done`/`skipped`), or enqueued when it has no row. Returns how many were queued.
    private func requeueDirtyRollups(now: Date, in d: Database) throws -> Int {
        let jobs = JobStore(db)
        var queued = 0
        for level in [ChronicleLevel.day, .week, .month, .year] {
            let rows = try Row.fetchAll(d, sql: """
                SELECT period_key, period_start, period_end FROM chronicle WHERE level = ? AND is_dirty = 1
                ORDER BY period_start, id
                """, arguments: [level.rawValue])
            for row in rows {
                let key: String = row["period_key"]
                let spec = JobSpec(kind: level.jobKind, periodKey: key, periodStart: row["period_start"],
                                   periodEnd: row["period_end"], notBefore: now)
                if try jobs.enqueue([spec], now: now, in: d) > 0 {
                    queued += 1
                } else if try jobs.requeue(kind: level.jobKind, periodKey: key, now: now, ifStatusIn: [.done, .skipped], in: d) {
                    queued += 1
                }
            }
        }
        return queued
    }

    /// Step 2 (plan pinned values, F-62). Returns how many pages were deleted.
    static func pruneStalePages(now: Date, in d: Database) throws -> Int {
        let candidates = try WikiPage.fetchAll(d, sql: """
            SELECT * FROM wiki_pages p
            WHERE p.mention_count <= 1 AND p.last_seen < ?
              AND NOT EXISTS (SELECT 1 FROM wiki_facts f WHERE f.slug = p.slug)
            ORDER BY p.id
            """, arguments: [now.addingTimeInterval(-pruneAfter)])
        guard !candidates.isEmpty else { return 0 }
        let named = Set(try Row.fetchAll(d, sql: "SELECT person, project FROM salient_flags WHERE status = 'open'")
            .flatMap { [TextFold.key($0["person"] as String), TextFold.key($0["project"] as String)] }
            .filter { !$0.isEmpty })
        var pruned = 0
        for page in candidates where !([page.title] + page.aliases).contains(where: { named.contains(TextFold.key($0)) }) {
            try d.execute(sql: "DELETE FROM wiki_pages WHERE id = ?", arguments: [page.id])
            pruned += d.changesCount
        }
        if pruned > 0 { try EmbeddingStore.deleteOrphans(in: d) }
        return pruned
    }

    /// Step 3a. Open flags in creation order; each merges into the first older survivor of the
    /// same kind, owner and person (folded) whose text is similar enough. Returns how many merged.
    static func mergeLoops(in d: Database) throws -> Int {
        let open = try SalientFlag.fetchAll(d, sql: "SELECT * FROM salient_flags WHERE status = 'open' ORDER BY created_at, id")
        var survivors: [String: [SalientFlag]] = [:]
        var merged = 0
        for flag in open {
            let group = [flag.kind.rawValue, flag.owner.rawValue, TextFold.key(flag.person)].joined(separator: "|")
            guard let index = survivors[group]?.firstIndex(where: { TextFold.jaccard($0.text, flag.text) >= mergeSimilarity }),
                  var survivor = survivors[group]?[index] else {
                survivors[group, default: []].append(flag)
                continue
            }
            var seen = Set<Int64>()
            survivor.snapshotIDs = (survivor.snapshotIDs + flag.snapshotIDs).filter { seen.insert($0).inserted }
            survivor.lastSeenAt = max(survivor.lastSeenAt, flag.lastSeenAt)
            survivor.dueAt = survivor.dueAt ?? flag.dueAt
            survivor.llmCallID = survivor.llmCallID ?? flag.llmCallID
            try d.execute(sql: "DELETE FROM salient_flags WHERE id = ?", arguments: [flag.id])
            try survivor.update(d)
            survivors[group]?[index] = survivor
            merged += 1
        }
        return merged
    }

    /// Step 3b (plan pinned values): aged loops and past events become `expired`, never `done`.
    static func expireLoops(now: Date, in d: Database) throws -> Int {
        let ids = try Int64.fetchAll(d, sql: """
            SELECT id FROM salient_flags WHERE status = 'open' AND (
                (kind IN ('todo', 'commitment') AND last_seen_at < ?)
                OR (kind = 'event' AND due_at IS NOT NULL AND due_at < ?))
            ORDER BY id
            """, arguments: [now.addingTimeInterval(-staleLoopAfter), now.addingTimeInterval(-eventGrace)])
        for id in ids {
            try SalientFlagStore.setStatus(id: id, .expired, closeSnapshotIDs: [], confidence: nil, at: now, in: d)
        }
        return ids.count
    }

    /// Step 3c (LLM, F-26/F-66): at most 10 checks a night, counting the `evidenceCheck` calls
    /// already made since `since` (a second run on the same night makes none). A flag that no
    /// longer is open when its verdict is written is left alone; a closing whose snapshot was
    /// deleted meanwhile stays open. An undecodable answer counts as "still open"; any other error
    /// ends the step.
    /// Flags citing only snapshots excluded now are never sent (`DerivedPolicy`, applied before
    /// the budget's first N are taken).
    private func checkLoops(context: JobContext, since: Date, report: inout CompactionReport) async throws {
        let policy = SnapshotPolicy.current(db)
        let flags = try await db.reader.read { d -> [SalientFlag] in
            let made = try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM llm_calls WHERE job_type = ? AND started_at >= ?",
                                        arguments: [JobType.evidenceCheck.rawValue, since]) ?? 0
            let budget = max(0, Self.maxLoopChecks - made)
            guard budget > 0 else { return [] }
            let open = try SalientFlag.fetchAll(d, sql: """
                SELECT * FROM salient_flags
                WHERE status = 'open' AND owner = 'user' AND kind IN ('commitment', 'todo')
                ORDER BY checked_at IS NOT NULL, checked_at, id
                """)
            return Array(try DerivedPolicy.filter(open, ids: \.snapshotIDs, policy: policy, in: d).prefix(budget))
        }
        let calls = LLMCallStore(db)
        for flag in flags {
            try Task.checkCancellation()
            guard let id = flag.id else { continue }
            let verdict: LoopVerdict
            do { verdict = try await loopCheck.check(flag, context: context) } catch let error as MemoryError {
                Self.log.info("loop check answer rejected: \(error.code, privacy: .public)")
                verdict = .open
            }
            report.loopsChecked += 1
            let closed = try DataGeneration.write(db, expected: context.generation) { d -> Bool in
                guard try SalientFlag.fetchOne(d, key: id)?.status == .open else { return false }
                if verdict.status == .done, let snapshot = verdict.closeSnapshotID,
                   try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM snapshots WHERE id = ?", arguments: [snapshot]) == 1 {
                    try SalientFlagStore.setStatus(id: id, .done, closeSnapshotIDs: [snapshot],
                                                   confidence: verdict.confidence, at: context.now, in: d)
                    if let call = verdict.callID { try calls.setArtifact(callID: call, table: "salient_flags", id: id, in: d) }
                    return true
                }
                try SalientFlagStore.setStatus(id: id, .open, closeSnapshotIDs: [], confidence: nil, at: context.now, in: d)
                return false
            }
            if closed { report.loopsClosed += 1 }
        }
    }

    /// Step 3d: model-owned notes (with an `llm_call_id`) deduplicated and capped by
    /// `StyleNotesMerge.merge(existing: [], new: bullets)`, keeping their call and `updated_at`
    /// (the style job's window). Notes the user owns are append-only and left alone. Returns how
    /// many bullets were dropped.
    private func mergeStyleNotes(in d: Database) throws -> Int {
        let notes = StyleNoteStore(db)
        var dropped = 0
        for row in try Row.fetchAll(d, sql: """
            SELECT surface, notes, updated_at, llm_call_id FROM style_notes WHERE llm_call_id IS NOT NULL ORDER BY surface
            """) {
            let text: String = row["notes"]
            let bullets = StyleNotesMerge.bullets(text)
            let merged = StyleNotesMerge.merge(existing: [], new: bullets)
            let rendered = StyleNotesMerge.render(merged)
            guard rendered != text else { continue }
            dropped += bullets.count - merged.count
            try notes.upsert(surface: row["surface"], notes: rendered, llmCallID: row["llm_call_id"],
                             at: row["updated_at"], in: d)
        }
        return dropped
    }

    /// The retention window's start (`now − n days`), nil for `.forever`. A corrupt setting throws
    /// (the step fails, nothing is deleted) rather than falling back to a window.
    private func retentionCutoff(now: Date) throws -> Date? {
        let setting = try SettingsStore(db).value(RetentionSetting.self, forKey: MemorySettings.retentionKey)
            ?? MemorySettings.defaultRetention
        guard case .days(let raw) = setting, case .days(let days) = RetentionSetting.days(clamping: raw) else { return nil }
        return now.addingTimeInterval(-Double(days) * 86_400)
    }

    /// Step 1 (`boilerplate_excluded`): stats and learned lines of surfaces the exclusions as they
    /// stand now deny (`BoilerplateSurface.allows`; an app judged under every name seen for its
    /// bundle id; a site by the domain in its `web:` key). The exclusions are read with a throwing
    /// read (never `SnapshotPolicy.current`): if they cannot load, the step fails and nothing is
    /// dropped. Surfaces and app names are read once, before the write; only the deletes run in the
    /// generation-checked write. Returns how many rows went.
    @discardableResult
    private func dropExcludedBoilerplate(context: JobContext) throws -> Int {
        let policy = CapturePolicy(userRules: try ExclusionStore(db).all().compactMap(ExclusionRule.init(pattern:)))
        let (surfaces, pairs) = try db.reader.read { d in
            (try BoilerplateStore.surfaces(in: d),
             try Row.fetchAll(d, sql: """
                SELECT DISTINCT bundle_id, app FROM snapshots WHERE bundle_id IS NOT NULL
                UNION SELECT DISTINCT bundle_id, app FROM activity_events WHERE bundle_id IS NOT NULL
                UNION SELECT DISTINCT bundle_id, app FROM snapshot_sources WHERE bundle_id IS NOT NULL AND app IS NOT NULL
                """).map { ($0["bundle_id"] as String, $0["app"] as String) })
        }
        var names: [String: [String]] = [:]
        for (bundle, app) in pairs { names[bundle, default: []].append(app) }
        let denied = surfaces.filter { surface in
            let key = surface.hasPrefix("app:") ? String(surface.dropFirst(4)) : ""
            return !BoilerplateSurface.allows(surface, appNames: names[key] ?? [], policy: policy)
        }
        guard !denied.isEmpty else { return 0 }
        return try DataGeneration.write(db, expected: context.generation) { d in
            try BoilerplateStore.drop(surfaces: denied, in: d)
        }
    }

    /// Whether this night already has a digest (one rebuild a night, F-6 ruling).
    private func digestBuilt(since nightStart: Date) throws -> Bool {
        try db.reader.read { d in
            try Bool.fetchOne(d, sql: "SELECT 1 FROM memory_digest WHERE created_at >= ? LIMIT 1", arguments: [nightStart]) ?? false
        }
    }

    /// Step 5. Each batch is re-checked inside its own generation-checked write. A corrupt
    /// retention setting fails the step (nothing is deleted) rather than falling back to a window.
    private func retention(context: JobContext, report: inout CompactionReport) throws {
        guard let cutoff = try retentionCutoff(now: context.now) else { return }
        let store = RetentionStore(db)
        for _ in 0..<Self.maxRetentionRounds {
            try Task.checkCancellation()
            let ids = try store.deletable(olderThan: cutoff, limit: RetentionStore.batchSize)
            guard !ids.isEmpty else { return }
            let deleted = try DataGeneration.write(db, expected: context.generation) { try RetentionStore.delete(ids, in: $0) }
            report.snapshotsDeleted += deleted
            if deleted == 0 { return }
        }
    }

    /// Step 5b (controller ruling relaxing F-36): uncovered, uncited snapshots older than the window
    /// whose app or site the exclusions as they stand now do not allow. The exclusions are read with
    /// a throwing read (never `SnapshotPolicy.current`, whose fallback is `.denyAll`): if they cannot
    /// load, the step fails and nothing is deleted. Citation is re-checked inside each write.
    private func deleteUnsummarisable(context: JobContext, report: inout CompactionReport) throws {
        guard let cutoff = try retentionCutoff(now: context.now) else { return }
        let policy = CapturePolicy(userRules: try ExclusionStore(db).all().compactMap(ExclusionRule.init(pattern:)))
        let store = RetentionStore(db)
        var after: Int64 = 0
        for _ in 0..<Self.maxRetentionRounds {
            try Task.checkCancellation()
            let page = try store.uncoveredCandidates(olderThan: cutoff, afterID: after, limit: RetentionStore.batchSize)
            guard let last = page.last?.id else { return }
            after = last
            let ids = page.filter { !SnapshotPolicy.allows($0, policy: policy) }.compactMap(\.id)
            guard !ids.isEmpty else { continue }
            report.snapshotsDeleted += try DataGeneration.write(db, expected: context.generation) {
                try RetentionStore.deleteUnsummarisable(ids, in: $0)
            }
        }
    }

    /// Step 6. False when the embedder is unavailable (only orphan vectors were dropped). Stops when
    /// nothing is pending, at 2,000 vectors, after a round without progress, or after 120 s.
    private func embed(context: JobContext, report: inout CompactionReport) async throws -> Bool {
        _ = try DataGeneration.write(db, expected: context.generation) { try EmbeddingStore.deleteOrphans(in: $0) }
        guard let identity = EmbeddingIndexer.usable(await embedder.identity()) else { return false }
        let indexer = EmbeddingIndexer(db: db, embedder: embedder), store = EmbeddingStore(db)
        let deadline = ContinuousClock.now + Self.embeddingTimeBudget
        var pending = try store.pendingSourceCount(identity: identity.pendingIdentity)
        var rounds = 0
        while pending > 0, report.embeddingsWritten < Self.maxEmbeddings, rounds < Self.maxEmbeddingRounds,
              ContinuousClock.now < deadline {
            try Task.checkCancellation()
            rounds += 1
            report.embeddingsWritten += try await indexer.run(
                limit: min(Self.embeddingBatch, Self.maxEmbeddings - report.embeddingsWritten),
                at: context.now, generation: context.generation)
            let left = try store.pendingSourceCount(identity: identity.pendingIdentity)
            if left >= pending { break }
            pending = left
        }
        return true
    }

    // MARK: - Helpers

    private func fileBytes() -> Int64 {
        guard let dbURL else { return 0 }
        let sizes = DatabaseStats.fileSizes(dbURL)
        return sizes.main + sizes.wal
    }

    static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? LLMError) == .cancelled
    }

    /// The scheduler's own classification, so compaction backs off exactly when any job would.
    static func isUsageLimit(_ error: any Error) -> Bool {
        MemoryScheduler.disposition(for: .failure(error), cancelRequested: false).isUsageLimit
    }

    /// An error code for the log: a `CodedError`'s code, `LLMError.errorCode`, or the type name.
    static func code(_ error: any Error) -> String {
        if let coded = error as? any CodedError { return coded.code }
        if let llm = error as? LLMError { return llm.errorCode ?? String(describing: type(of: error)) }
        return String(describing: type(of: error))
    }
}
