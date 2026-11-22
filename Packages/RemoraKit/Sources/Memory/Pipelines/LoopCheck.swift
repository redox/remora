import Capture
import Foundation
import GRDB
import LLM
import Redaction
import Retrieval
import Storage
import os

/// The outcome of one open-loop check. `.done` only with verified evidence; `closeSnapshotID` is
/// the snapshot that shows it. `callID` is the model call, when one was made.
public struct LoopVerdict: Sendable, Equatable {
    public var status: FlagStatus
    public var confidence: Double
    public var closeSnapshotID: Int64?
    public var callID: Int64?

    public init(status: FlagStatus, confidence: Double, closeSnapshotID: Int64? = nil, callID: Int64? = nil) {
        self.status = status; self.confidence = confidence; self.closeSnapshotID = closeSnapshotID; self.callID = callID
    }

    static let open = LoopVerdict(status: .open, confidence: 0)
}

/// Checks whether an open loop (a commitment or todo) has been done (small tier, job type
/// `evidenceCheck`). Compaction step 3 runs it on at most 10 loops a night and writes the verdict.
///
/// - Evidence: snapshots captured after the flag was recorded that match its person, project and
///   text terms (`SnapshotStore.searchAny`), filtered by the exclusions as they stand now
///   (`SnapshotPolicy`, `.denyAll` when they cannot load), deduped, oldest first, fitted to 12,000
///   characters. No evidence, or the cloud denied: no call, the loop stays open.
/// - The prompt frames the flag and the snapshots as untrusted, escaped data. Done means a capture
///   shows the owed outcome happened; plans, drafts, intentions, a newer message from the other
///   person, silence or age are not done.
/// - `.done` only when the model says done with confidence ≥ 0.7 **and** its quote (redacted, as
///   all model output) is literally in the text of the snapshot it cites (`QuoteCheck`). Anything
///   else is `.open`; loops never close on age (compaction expires them instead).
public struct LoopCheck: Sendable {
    public static let maxEvidenceChars = 12_000
    public static let perItemChars = 3_000
    public static let minShareChars = 400
    /// Search hits read before the policy filter and the character budget.
    public static let maxHits = 24
    public static let minConfidence = 0.7
    static let maxTerms = 8

    private let db: AppDatabase
    private let llm: LLMService
    private let calendar: Calendar
    private let redactor: Redactor
    private static let log = Logger(subsystem: "dev.remora", category: "memory")

    public init(db: AppDatabase, llm: LLMService, calendar: Calendar, redactor: Redactor = .init()) {
        self.db = db; self.llm = llm; self.calendar = calendar; self.redactor = redactor
    }

    public func check(_ f: SalientFlag, context: JobContext) async throws -> LoopVerdict {
        guard context.cloudAllowed else { return .open }
        let items = try evidence(for: f, now: context.now)
        guard !items.isEmpty else { return .open }
        let span = DateInterval(start: min(f.createdAt, context.now), end: max(f.createdAt, context.now))
        let result = try await llm.complete(.evidenceCheck, instructions: PipelinePrompt.instructions(
            .checker, language: context.language, now: context.now, calendar: calendar),
                                            input: [.user(PipelinePrompt.loopBlock(f, calendar: calendar)),
                                                    .user(PipelinePrompt.evidenceBlock(
                                                        HourEvidence(span: span, items: items, activity: []),
                                                        calendar: calendar)),
                                                    .user(PipelinePrompt.loopCheckTask)],
                                            format: LoopCheckOutput.format, cloudAllowed: context.cloudAllowed)
        let output = try LoopCheckOutput.decode(result.text)
        let call = result.callID > 0 ? result.callID : nil
        let confidence = output.confidence.isFinite ? min(max(output.confidence, 0), 1) : 0
        let quote = redactor.redact(output.quote)
        guard output.done, confidence >= Self.minConfidence, (1...items.count).contains(output.evidence),
              QuoteCheck.verify(quote, in: items[output.evidence - 1].text) else {
            Self.log.info("loop check: open (\(items.count, privacy: .public) snapshots)")
            return LoopVerdict(status: .open, confidence: confidence, callID: call)
        }
        Self.log.info("loop check: done (\(items.count, privacy: .public) snapshots)")
        return LoopVerdict(status: .done, confidence: confidence, closeSnapshotID: items[output.evidence - 1].snapshotID,
                           callID: call)
    }

    /// The numbered evidence for `f` (see the type comment).
    func evidence(for f: SalientFlag, now: Date) throws -> [EvidenceItem] {
        let terms = QueryTerms.extract(from: [f.person, f.project, f.text], max: Self.maxTerms)
        guard !terms.isEmpty else { return [] }
        let store = SnapshotStore(db)
        let hits = try store.searchAny(terms: terms, since: f.createdAt, limit: Self.maxHits)
        guard !hits.isEmpty else { return [] }
        let newer = try store.snapshots(ids: hits.map(\.id)).filter { $0.capturedAt > f.createdAt && $0.capturedAt <= now }
        return HourEvidence.items(HourEvidence.allowed(newer, policy: SnapshotPolicy.current(db)),
                                  maxChars: Self.maxEvidenceChars, perItem: Self.perItemChars,
                                  minShare: Self.minShareChars)
    }
}

extension PipelinePrompt {
    /// The loop being checked, in `<memory>`: kind, whose, text, person, project, due date, when it
    /// was recorded and the words it was recorded from. Every stored string is escaped.
    public static func loopBlock(_ f: SalientFlag, calendar: Calendar) -> String {
        let due = f.dueAt.map { stamp($0, calendar: calendar, format: "yyyy-MM-dd HH:mm") } ?? ""
        var out = "<memory>\nOpen item (kind | whose | text | person | project | due | recorded):\n"
        out += "- \(f.kind.rawValue) | \(f.owner.rawValue) | \(oneLine(f.text, max: maxFlagChars)) | "
            + "\(oneLine(f.person, max: maxNameChars)) | \(oneLine(f.project, max: maxNameChars)) | \(due) | "
            + "\(stamp(f.createdAt, calendar: calendar, format: "yyyy-MM-dd HH:mm"))\n"
        if !f.quote.isEmpty { out += "Recorded from: \(oneLine(f.quote, max: maxFlagChars))\n" }
        return out + "</memory>"
    }

    /// A stored flag is at most 200 characters (plan output caps).
    static let maxFlagChars = 200

    /// The loop check task (job `evidenceCheck`, schema `loop_check`).
    public static let loopCheckTask = """
        Task: decide whether the open item in <memory> is now done, using only the snapshots above, which were captured after it was recorded.
        - done: true only when a snapshot shows that the owed outcome actually happened (the thing was sent, delivered, paid, booked, submitted or answered). A plan, a draft, an intention, a reminder, a newer message from the other person, silence or the time that has passed do not make it done.
        - confidence: from 0 (nothing supports it) to 1 (a snapshot plainly shows it happened).
        - evidence: the number (n) of the snapshot that shows it, or 0 when done is false.
        - quote: the words of that snapshot that show it, copied exactly; "" when done is false.
        """
}
