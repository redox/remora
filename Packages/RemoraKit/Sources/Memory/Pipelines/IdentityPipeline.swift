import Capture
import Foundation
import GRDB
import LLM
import Redaction
import Retrieval
import Storage
import os

/// Runs an `identity` job (large tier, job type `identity`): rewrites the profile of who the user
/// is from the current profile, the last 14 day chronicles, the 30 pages most mentioned in the
/// last 30 days and samples of the user's own writing.
///
/// - The user's edits win (F-33). The constraints are replayed over the whole revision history
///   (`IdentityMerge.constraints`): lines the user added are re-added under `### Notes from you`
///   when the model leaves them out, lines the user removed are dropped from the output.
///   The constraints are computed again inside the write, so an edit made while the call ran
///   is honoured too and never overwritten.
/// - Chronicles and pages citing snapshots now excluded (`DerivedPolicy`), and samples from apps
///   or sites excluded now, never reach the prompt. Cloud denied: skipped, no call.
/// - Output is cut, enforced, redacted, then stored as an `llm` revision with the call id and
///   artifact in one generation-checked write.
/// - Samples come from inline outputs only; captured user-authored text as a source is a
///   follow-up (F-63).
public struct IdentityPipeline: JobRunner {
    public static let days = 14
    public static let maxPages = 30
    public static let pageWindow: TimeInterval = 30 * 86_400
    public static let maxSamples = 20
    public static let maxSampleChars = 600
    /// Inline outputs read (newest first) before the policy filter and the sample limit.
    public static let sampleWindow = 200

    private let db: AppDatabase
    private let llm: LLMService
    private let calendar: Calendar
    private let redactor: Redactor
    private static let log = Logger(subsystem: "dev.remora", category: "memory")

    public init(db: AppDatabase, llm: LLMService, calendar: Calendar, redactor: Redactor = .init()) {
        self.db = db; self.llm = llm; self.calendar = calendar; self.redactor = redactor
    }

    public func run(_ job: Job, context: JobContext) async throws -> JobOutcome {
        guard job.kind == .identity else { return .skipped("wrong_kind") }
        guard context.cloudAllowed else { return .skipped("cloud_denied") }
        let now = context.now
        let policy = SnapshotPolicy.current(db)
        let recent = try InlineOutputStore(db).recent(limit: Self.sampleWindow)
        let (current, history, days, pages) = try await db.reader.read { d -> (IdentityRevision?, [IdentityRevision], [Chronicle], [WikiPage]) in
            let history = try IdentityStore.all(in: d)
            let newestDays = try Chronicle.fetchAll(d, sql: """
                SELECT * FROM chronicle WHERE level = 'day' AND period_start < ?
                ORDER BY period_start DESC, id DESC LIMIT ?
                """, arguments: [now, Self.days * 2])
            let top = try WikiPage.fetchAll(d, sql: """
                SELECT * FROM wiki_pages WHERE last_seen >= ? AND mention_count > 0
                ORDER BY mention_count DESC, last_seen DESC, id DESC LIMIT ?
                """, arguments: [now.addingTimeInterval(-Self.pageWindow), Self.maxPages * 2])
            let days = try DerivedPolicy.filter(newestDays, ids: \.snapshotIDs, policy: policy, in: d).prefix(Self.days).reversed()
            return (history.last, history, Array(days),
                    try DerivedPolicy.filter(top, ids: \.snapshotIDs, policy: policy, in: d).prefix(Self.maxPages).map { $0 })
        }
        let samples = Self.samples(from: recent, policy: policy)
        guard !days.isEmpty || !pages.isEmpty || !samples.isEmpty else { return .skipped("no_evidence") }

        let constraints = IdentityMerge.constraints(history)
        let block = PipelinePrompt.identityBlock(current: current?.body, days: days, pages: pages, calendar: calendar)
        let task = PipelinePrompt.identityTask(samples: samples, mustKeep: constraints.mustKeep,
                                               mustNotReintroduce: constraints.mustNotReintroduce)
        let result = try await llm.complete(.identity, instructions: PipelinePrompt.instructions(
            .curator, language: context.language, now: now, calendar: calendar),
                                            input: [.user(block), .user(task)], format: IdentityOutput.format,
                                            cloudAllowed: context.cloudAllowed)
        let output = try IdentityOutput.decode(result.text)
        let raw = String(output.identity.trimmingCharacters(in: .whitespacesAndNewlines).prefix(IdentityOutput.maxChars))
        guard !raw.isEmpty else { throw MemoryError.invalidOutput(schema: IdentityOutput.schemaName) }
        let call = result.callID > 0 ? result.callID : nil
        let store = IdentityStore(db), calls = LLMCallStore(db)
        let redactor = self.redactor
        let stored = try DataGeneration.write(db, expected: context.generation) { d -> IdentityRevision in
            // Re-read the history now: a user edit made during the call counts.
            let fresh = IdentityMerge.constraints(try IdentityStore.all(in: d))
            let body = redactor.redact(IdentityMerge.enforce(output: raw, mustKeep: fresh.mustKeep,
                                                             mustNotReintroduce: fresh.mustNotReintroduce))
            let row = try store.insertLLM(body, llmCallID: call, at: now, in: d)
            if let call { try calls.setArtifact(callID: call, table: "identity", id: row.id, in: d) }
            return row
        }
        Self.log.info("identity \(job.periodKey, privacy: .public): \(days.count, privacy: .public) days, \(pages.count, privacy: .public) pages, \(samples.count, privacy: .public) samples, keep \(constraints.mustKeep.count, privacy: .public), never \(constraints.mustNotReintroduce.count, privacy: .public), stored \(stored.id != nil, privacy: .public)")
        return .done
    }

    /// The user's own writing: the `original` of `.full` and `.selection` outputs and the
    /// `finalText` of `.edited` ones, newest first, each cut to `maxSampleChars`, without repeats
    /// and without outputs of apps or sites excluded now.
    static func samples(from outputs: [InlineOutput], policy: CapturePolicy) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for o in outputs where SnapshotPolicy.allows(o, policy: policy) {
            var texts: [String] = []
            if o.mode == .full || o.mode == .selection { texts.append(o.original) }
            if o.outcome == .edited, let final = o.finalText { texts.append(final) }
            for text in texts {
                let cut = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxSampleChars))
                guard !cut.isEmpty, seen.insert(TextFold.key(cut)).inserted, out.count < maxSamples else { continue }
                out.append(cut)
            }
        }
        return out
    }
}

extension PipelinePrompt {
    static let maxIdentityBodyChars = 4_000
    static let maxRuleLineChars = 300

    /// The identity input: one `<memory>` section with the current profile, the day summaries
    /// (oldest first) and the pages (title | type | mentions | summary). Stored text is escaped.
    public static func identityBlock(current: String?, days: [Chronicle], pages: [WikiPage], calendar: Calendar) -> String {
        var out = "<memory>\n"
        if let current, !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out += "Current identity profile:\n\(escape(String(current.prefix(maxIdentityBodyChars))))\n"
        }
        if !days.isEmpty {
            out += "Day summaries, oldest first ([date] summary):\n"
            for c in days {
                out += "[\(stamp(c.periodStart, calendar: calendar, format: "yyyy-MM-dd"))] \(oneLine(c.summary, max: maxChildSummaryChars))\n"
            }
        }
        if !pages.isEmpty {
            out += "Most mentioned pages, last 30 days (title | type | mentions | summary):\n"
            for p in pages {
                out += "- \(oneLine(p.title, max: maxNameChars)) | \(p.type.rawValue) | \(p.mentionCount) | "
                    + "\(oneLine(p.summary, max: maxSummaryPromptChars))\n"
            }
        }
        return out + "</memory>"
    }

    /// The identity task, with the user's samples in `<samples>` and the user's edit rules.
    public static func identityTask(samples: [String], mustKeep: [String], mustNotReintroduce: [String]) -> String {
        var out = ""
        if !samples.isEmpty {
            out += "<samples>\nText the user wrote themselves:\n"
                + samples.map { "- \(oneLine($0, max: IdentityPipeline.maxSampleChars))" }.joined(separator: "\n") + "\n</samples>\n\n"
        }
        out += """
            Task: rewrite the user's identity profile from <memory> and <samples>: who they are, in the third person, current truth only.
            - identity: markdown with exactly these sections: ### Role & focus, ### Projects, ### People, ### Tools & stack, ### Habits & patterns, ### Communication style.
            - Keep what the current profile says unless the evidence contradicts it. Do not invent anything the evidence does not support.
            """
        if !mustKeep.isEmpty {
            out += "\n- Rule: keep these lines verbatim (the user wrote them):\n"
                + mustKeep.map { "  * \(oneLine($0, max: maxRuleLineChars))" }.joined(separator: "\n")
        }
        if !mustNotReintroduce.isEmpty {
            out += "\n- Rule: the user removed these lines; do not reintroduce them:\n"
                + mustNotReintroduce.map { "  * \(oneLine($0, max: maxRuleLineChars))" }.joined(separator: "\n")
        }
        return out
    }
}
