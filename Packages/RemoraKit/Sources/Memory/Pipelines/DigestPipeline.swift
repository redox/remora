import Capture
import Foundation
import GRDB
import LLM
import Redaction
import Retrieval
import Storage
import os

/// Rebuilds the memory digest (large tier, job type `memoryDigest`): a compact, dated, third-person
/// profile of what the user is doing now, built from the identity profile, the last 7 day
/// chronicles, the 25 most recently seen pages (≥ 2 mentions, last 30 days) and the open flags.
/// Compaction step 4 calls `rebuild`.
///
/// - Rows citing snapshots now excluded never reach the prompt (`DerivedPolicy`). Nothing to
///   summarise (no day chronicle and no page), or the cloud denied: nil, no call.
/// - Output is redacted and cut to 8,000 characters. The insert (keeping the newest 7) and the
///   call's artifact are one generation-checked write; when a page or day it was built from was
///   deleted meanwhile nothing is stored (nil).
/// - After a forget the digest is "dirty" (`markDirty`, setting `memory.digestDirtySince`): the
///   forget runs only this rebuild (`DigestRebuildRunner`, job `digest_rebuild`), and compaction
///   rebuilds it even when a digest was built the same night. A stored rebuild clears the mark it
///   started from (a newer forget's mark stays). A dirty digest with nothing left to summarise is
///   deleted rather than kept naming forgotten content.
public struct DigestPipeline: Sendable {
    public static let days = 7
    public static let maxPages = 25
    public static let pageWindow: TimeInterval = 30 * 86_400
    public static let maxFlags = 20

    private let db: AppDatabase
    private let llm: LLMService
    private let identity: any IdentityReading
    private let calendar: Calendar
    private let redactor: Redactor
    private static let log = Logger(subsystem: "dev.remora", category: "memory")

    public init(db: AppDatabase, llm: LLMService, identity: any IdentityReading, calendar: Calendar,
                redactor: Redactor = .init()) {
        self.db = db; self.llm = llm; self.identity = identity; self.calendar = calendar; self.redactor = redactor
    }

    /// Setting: when the digest was last marked dirty by a forget (nil: clean).
    public static let dirtyKey = ForgetMarks.digestDirtyKey

    public static func markDirty(_ db: AppDatabase, at: Date) throws {
        try SettingsStore(db).setValue(at, forKey: dirtyKey)
    }

    public static func dirtySince(_ db: AppDatabase) throws -> Date? {
        try SettingsStore(db).value(Date.self, forKey: dirtyKey)
    }

    /// Clears the mark only if it is still the one read before the rebuild.
    public static func clearDirty(_ db: AppDatabase, ifMarkedAt mark: Date) throws {
        try db.writer.write { d in try clearDirty(db, ifMarkedAt: mark, in: d) }
    }

    static func clearDirty(_ db: AppDatabase, ifMarkedAt mark: Date?, in d: Database) throws {
        guard let mark else { return }
        let settings = SettingsStore(db)
        if try settings.value(Date.self, forKey: dirtyKey, in: d) == mark {
            try settings.setValue(Date?.none, forKey: dirtyKey, in: d)
        }
    }

    public func rebuild(context: JobContext) async throws -> MemoryDigest? {
        guard context.cloudAllowed else { return nil }
        let now = context.now
        let dirtyMark = try? Self.dirtySince(db)
        let policy = SnapshotPolicy.current(db)
        let profile = try identity.current()
        // The local day 6 days back starts the window: today plus the 6 days before it.
        let windowStart = calendar.date(byAdding: .day, value: -(Self.days - 1), to: calendar.startOfDay(for: now))
            ?? now.addingTimeInterval(-Double(Self.days) * 86_400)
        let flagStore = SalientFlagStore(db)
        let flagRows = try flagStore.open(kinds: Set(FlagKind.allCases), limit: Self.maxFlags * 2)
        let (days, pages, flags) = try await db.reader.read { d -> ([Chronicle], [WikiPage], [SalientFlag]) in
            let newestDays = try Chronicle.fetchAll(d, sql: """
                SELECT * FROM chronicle WHERE level = 'day' AND period_start >= ? AND period_start < ?
                ORDER BY period_start DESC, id DESC LIMIT ?
                """, arguments: [windowStart, now, Self.days * 2])
            let pages = try WikiPage.fetchAll(d, sql: """
                SELECT * FROM wiki_pages WHERE mention_count >= 2 AND last_seen >= ?
                ORDER BY last_seen DESC, id DESC LIMIT ?
                """, arguments: [now.addingTimeInterval(-Self.pageWindow), Self.maxPages * 2])
            let days = try DerivedPolicy.filter(newestDays, ids: \.snapshotIDs, policy: policy, in: d).prefix(Self.days).reversed()
            return (Array(days),
                    try DerivedPolicy.filter(pages, ids: \.snapshotIDs, policy: policy, in: d).prefix(Self.maxPages).map { $0 },
                    try DerivedPolicy.filter(flagRows, ids: \.snapshotIDs, policy: policy, in: d).prefix(Self.maxFlags).map { $0 })
        }
        guard !days.isEmpty || !pages.isEmpty else {
            if let dirtyMark = dirtyMark ?? nil {
                // Forgotten down to nothing: the old digest would keep naming it.
                try DataGeneration.write(db, expected: context.generation) { d in
                    try d.execute(sql: "DELETE FROM memory_digest")
                    // No call may point at a deleted digest.
                    try d.execute(sql: "UPDATE llm_calls SET artifact_table = NULL, artifact_id = NULL WHERE artifact_table = 'memory_digest'")
                    try Self.clearDirty(db, ifMarkedAt: dirtyMark, in: d)
                }
                Self.log.info("memory digest: nothing left after a forget, deleted")
            }
            return nil
        }

        let block = PipelinePrompt.digestBlock(identity: profile?.body, days: days, pages: pages, flags: flags,
                                               calendar: calendar)
        let result = try await llm.complete(.memoryDigest, instructions: PipelinePrompt.instructions(
            .curator, language: context.language, now: now, calendar: calendar),
                                            input: [.user(block), .user(PipelinePrompt.digestTask)],
                                            format: MemoryDigestOutput.format, cloudAllowed: context.cloudAllowed)
        let output = try MemoryDigestOutput.decode(result.text)
        let text = String(redactor.redact(output.digest).trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(MemoryDigestOutput.maxChars))
        guard !text.isEmpty else { throw MemoryError.invalidOutput(schema: MemoryDigestOutput.schemaName) }
        let call = result.callID > 0 ? result.callID : nil
        let usedDays = days.compactMap(\.id), usedPages = pages.compactMap(\.id)
        let store = MemoryDigestStore(db), calls = LLMCallStore(db)
        let stored = try DataGeneration.write(db, expected: context.generation) { d -> MemoryDigest? in
            for (table, ids) in [("chronicle", usedDays), ("wiki_pages", usedPages)] where !ids.isEmpty {
                let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
                let alive = try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM \(table) WHERE id IN (\(marks))",
                                             arguments: StatementArguments(ids)) ?? 0
                if alive != ids.count { return nil }
            }
            let row = try store.insert(MemoryDigest(body: text, createdAt: now, llmCallID: call), in: d)
            if let call { try calls.setArtifact(callID: call, table: "memory_digest", id: row.id, in: d) }
            try Self.clearDirty(db, ifMarkedAt: dirtyMark ?? nil, in: d)
            return row
        }
        Self.log.info("memory digest: \(days.count, privacy: .public) days, \(pages.count, privacy: .public) pages, \(flags.count, privacy: .public) flags, stored \(stored != nil, privacy: .public)")
        return stored
    }
}

extension PipelinePrompt {
    static let maxIdentityChars = 2_000

    /// The digest input: one `<memory>` section with the identity, the day summaries (oldest
    /// first), the pages (title | type | summary) and the open flags. Stored strings are escaped.
    public static func digestBlock(identity: String?, days: [Chronicle], pages: [WikiPage], flags: [SalientFlag],
                                   calendar: Calendar) -> String {
        var out = "<memory>\n"
        if let identity, !identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out += "Identity profile:\n\(escape(String(identity.prefix(maxIdentityChars))))\n"
        }
        if !days.isEmpty {
            out += "Day summaries, oldest first ([date] summary):\n"
            for c in days {
                out += "[\(stamp(c.periodStart, calendar: calendar, format: "yyyy-MM-dd"))] "
                    + "\(oneLine(c.summary, max: maxChildSummaryChars))\n"
            }
        }
        if !pages.isEmpty {
            out += "Pages seen recently (title | type | summary):\n"
            for p in pages {
                out += "- \(oneLine(p.title, max: maxNameChars)) | \(p.type.rawValue) | \(oneLine(p.summary, max: maxSummaryPromptChars))\n"
            }
        }
        if !flags.isEmpty {
            out += "Open flags (kind | owner | text | person | due):\n"
            for f in flags {
                let due = f.dueAt.map { stamp($0, calendar: calendar, format: "yyyy-MM-dd") } ?? ""
                out += "- \(f.kind.rawValue) | \(f.owner.rawValue) | \(oneLine(f.text, max: maxFactChars)) | "
                    + "\(oneLine(f.person, max: maxNameChars)) | \(due)\n"
            }
        }
        return out + "</memory>"
    }

    /// The digest task (job `memoryDigest`, schema `memory_digest`).
    public static let digestTask = """
        Task: write the user's memory digest from <memory>: a compact profile of who the user is and what they are doing now, for another assistant to read before answering.
        - digest: at most 600 words of markdown, in the third person, with exactly these sections: ### Current focus, ### Active projects, ### People, ### Open commitments, ### Preferences & tools.
        - Prefix every time-sensitive fact with its date as [yyyy-MM-dd].
        - Current truth only: leave out what is finished or no longer true. Do not invent anything <memory> does not support.
        """
}

/// Job `digest_rebuild`: the digest alone, after a forget (never a full compaction). With the cloud
/// denied it does nothing and the dirty mark stays for compaction.
public struct DigestRebuildRunner: JobRunner {
    private let digest: DigestPipeline

    public init(digest: DigestPipeline) { self.digest = digest }

    public func run(_ job: Job, context: JobContext) async throws -> JobOutcome {
        guard context.cloudAllowed else { return .skipped("cloud_denied") }
        _ = try await digest.rebuild(context: context)
        return .done
    }
}

/// What a forget (chat `forget_snapshots`, Settings) runs afterwards: marks the digest dirty, then
/// rebuilds only the digest through `runNow` (gate, budget and backoff apply; when they deny it,
/// the pending job and the dirty mark make a later tick or compaction rebuild it).
public enum ForgetFollowUp {
    @discardableResult
    public static func rebuildDigest(db: AppDatabase, scheduler: MemoryScheduler, signals: SchedulerSignals,
                                     calendar: Calendar) async -> TickReport {
        do { try DigestPipeline.markDirty(db, at: signals.now) } catch {
            Logger(subsystem: "dev.remora", category: "memory")
                .error("digest dirty mark not saved: \(String(describing: type(of: error)), privacy: .public)")
        }
        return await scheduler.runNow(kind: .digestRebuild, periodKey: PeriodKey.key(.day, for: signals.now, calendar: calendar),
                                      signals: signals)
    }
}
