import Capture
import Foundation
import GRDB
import LLM
import Memory
import Retrieval
import Storage
import os

/// The `nudge_triage` schema: one verdict per listed flag.
public struct NudgeTriageOutput: PipelineOutput, Equatable {
    public struct Decision: Decodable, Sendable, Equatable {
        public var flagID: Int64
        public var notify: Bool
        public var reason: String

        enum CodingKeys: String, CodingKey {
            case notify, reason
            case flagID = "flag_id"
        }
    }

    public var decisions: [Decision]

    public static let schemaName = "nudge_triage"
    public static let schema = JSONSchema.object([
        "decisions": JSONSchema.array(JSONSchema.object([
            "flag_id": JSONSchema.integer,
            "notify": JSONSchema.boolean,
            "reason": JSONSchema.string(),
        ])),
    ])
}

/// One nudge scan (`nudge_scan`, a 30-minute slot planned by `ProactivePlanner`). At most one
/// nudge per scan, at most 3 a day, 90 minutes apart, only 09:00–19:00 and only when the user can
/// be interrupted (not idle, not sharing their screen):
/// 1. gates (a failed gate records nothing and makes no model call);
/// 2. candidates (`NudgeCandidates`, fresh exclusions);
/// 3. triage of ≤ 3 flags in one small-model call; each `notify: false` is recorded `declined`;
/// 4. the first flag to notify must still have its quote, literally, in one of its existing,
///    allowed snapshots (`QuoteCheck`), else it is recorded `unverified`;
/// 5. `VerifiedWriter` writes ≤ 280 characters from the flag, its quote, excerpts of its snapshots
///    and the clock; a rejected draft is recorded `unverified`;
/// 6. the gates that can change during the write (the window, interruptibility) are checked again,
///    then `ProactiveInbox.deliver` rechecks the switches, memory and fresh exclusions and stores the nudge under the cap and records `sent` in the same
///    transaction. Nothing is recorded when delivery is refused (cap, gap, changed evidence), so
///    the flag may be tried another time.
///
/// Every decision is written through `DataGeneration.write(expected:)`. Skip codes are codes;
/// nothing captured or written is ever logged.
public struct NudgeRunner: JobRunner {
    public static let maxChars = 280
    /// Excerpts of the flag's snapshots, in all (pinned value).
    public static let excerptChars = 4_000
    static let maxExcerpts = 4
    static let triageEvidenceChars = 8_000

    private let db: AppDatabase
    private let llm: LLMService
    private let writer: VerifiedWriter
    private let inbox: ProactiveInbox
    private let policy: @Sendable () -> CapturePolicy
    private let enabled: @Sendable () -> Bool
    private let canInterrupt: @Sendable () async -> Bool
    private let now: @Sendable () -> Date
    private static let log = Logger(subsystem: "dev.remora", category: "proactive")

    /// `policy` loads the exclusions fresh (`SnapshotPolicy.current`). `canInterrupt` is false
    /// when the user has been idle more than 600 s or is sharing their screen. `now` is read again
    /// after the (slow) write, for delivery.
    public init(db: AppDatabase, llm: LLMService, writer: VerifiedWriter, inbox: ProactiveInbox,
                policy: @escaping @Sendable () -> CapturePolicy, enabled: @escaping @Sendable () -> Bool,
                canInterrupt: @escaping @Sendable () async -> Bool, now: @escaping @Sendable () -> Date = Date.init) {
        self.db = db; self.llm = llm; self.writer = writer; self.inbox = inbox; self.policy = policy
        self.enabled = enabled; self.canInterrupt = canInterrupt; self.now = now
    }

    public func run(_ job: Job, context: JobContext) async throws -> JobOutcome {
        if let skip = try await gate(context) { return .skipped(skip) }
        let calendar = context.calendar
        let policy = policy()
        let candidates = try NudgeCandidates.select(db: db, policy: policy, now: context.now, calendar: calendar)
        guard !candidates.isEmpty else { return .skipped("nothing") }

        // 3. Triage.
        let triage = try await llm.complete(
            .nudgeTriage, instructions: ProactivePrompt.triage(now: context.now, calendar: calendar),
            input: [.user(Self.triageEvidence(candidates, now: context.now, calendar: calendar)
                        .block(maxChars: Self.triageEvidenceChars)),
                    .user("Decide, for each item, whether to nudge the user about it now.")],
            format: NudgeTriageOutput.format, cloudAllowed: context.cloudAllowed)
        let triageCall = triage.callID > 0 ? triage.callID : nil
        var verdicts: [Int64: Bool] = [:]
        for d in try NudgeTriageOutput.decode(triage.text).decisions where verdicts[d.flagID] == nil {
            verdicts[d.flagID] = d.notify   // unknown ids never match a candidate below
        }
        let declined = candidates.filter { $0.id.map { verdicts[$0] == false } ?? false }
        try record(declined, .declined, callID: triageCall, context: context)
        guard let flag = candidates.first(where: { $0.id.map { verdicts[$0] == true } ?? false }),
              let flagID = flag.id else { return .skipped("declined") }

        // 4. The quote, against the flag's snapshots as they are now.
        let snapshots = try liveSnapshots(flag, policy: policy)
        let quoted = snapshots.filter { QuoteCheck.verify(flag.quote, in: $0.text) }
        guard !quoted.isEmpty else {
            try record([flag], .unverified, callID: triageCall, context: context)
            return .skipped("unverified")
        }

        // 5. Write and verify.
        let evidence = Self.writeEvidence(flag, snapshots: quoted + snapshots.filter { s in !quoted.contains { $0.id == s.id } },
                                          now: context.now, calendar: calendar)
        let result = try await writer.write(job: .nudgeWrite, kind: .nudge, evidence: evidence, task: Self.task,
                                            maxChars: Self.maxChars, context: context)
        guard case .accepted(let text, let writeCalls) = result else {
            if case .rejected(_, let calls) = result {
                try record([flag], .unverified, callID: calls.last ?? triageCall, context: context)
            }
            return .skipped("unverified")
        }

        // 6. Deliver, if the user can still be interrupted now.
        let at = now()
        guard Self.inWindow(at, calendar: calendar) else { return .skipped("outside window") }
        guard await canInterrupt() else { return .skipped("cannot interrupt") }
        let callIDs = [triageCall].compactMap { $0 } + writeCalls
        let dedupeKey = "nudge:\(flagID)"
        let decision = NudgeDecision(flagID: flagID, decision: .sent, flagLastSeenAt: flag.lastSeenAt, decidedAt: at,
                                     llmCallID: writeCalls.first ?? triageCall)
        let stored = try await inbox.deliver(
            kind: .nudge, title: "Nudge", body: text, dedupeKey: dedupeKey, callIDs: callIDs, flagID: flagID,
            expectedGeneration: context.generation,
            nudgeCap: (ProactivePlanner.dailyNudgeCap, ProactivePlanner.nudgeGap, calendar.startOfDay(for: at)),
            evidence: [EvidenceSource(table: "salient_flags", id: flagID, snapshotIDs: flag.snapshotIDs)], at: at,
            policy: self.policy(),   // fresh: an exclusion added during the write must win
            onStored: { [db] _, d in try NudgeDecisionStore(db).record(decision, in: d) })
        guard stored != nil else {
            if try inbox.delivered(dedupeKey: dedupeKey) { return .skipped("duplicate") }
            if !enabled() { return .skipped("disabled") }
            return .skipped(try capped(at, calendar: calendar) ?? "evidence changed")
        }
        Self.log.info("nudge delivered")
        return .done
    }

    // MARK: - Gates

    /// The first failed gate's code, or nil.
    private func gate(_ context: JobContext) async throws -> String? {
        guard enabled() else { return "disabled" }
        guard MemorySettings(SettingsStore(db)).enabled() else { return "memory off" }
        guard Self.inWindow(context.now, calendar: context.calendar) else { return "outside window" }
        guard context.cloudAllowed else { return "cloud_denied" }
        if let capped = try capped(context.now, calendar: context.calendar) { return capped }
        guard await canInterrupt() else { return "cannot interrupt" }
        return nil
    }

    /// `cap` (3 today) or `gap` (the last nudge < 90 min ago), counting nudges a cleared chat no
    /// longer shows (`InboxStore`'s nudge log).
    private func capped(_ at: Date, calendar: Calendar) throws -> String? {
        let store = InboxStore(db)
        if try store.nudgeCount(since: calendar.startOfDay(for: at)) >= ProactivePlanner.dailyNudgeCap { return "cap" }
        if let last = try store.lastNudgeAt(), at.timeIntervalSince(last) < ProactivePlanner.nudgeGap { return "gap" }
        return nil
    }

    static func inWindow(_ at: Date, calendar: Calendar) -> Bool {
        ProactivePlanner.nudgeHours.contains(calendar.component(.hour, from: at))
    }

    // MARK: - Reads and writes

    /// The flag's cited snapshots that still exist and the policy allows, newest first.
    private func liveSnapshots(_ flag: SalientFlag, policy: CapturePolicy) throws -> [Snapshot] {
        try db.reader.read { d in
            let allowed = try DerivedPolicy.allowedIDs(flag.snapshotIDs, policy: policy, in: d)
            guard !allowed.isEmpty else { return [] }
            return try Snapshot.filter(keys: Array(allowed))
                .order(Column("captured_at").desc, Column("id").desc).fetchAll(d)
        }
    }

    /// Records `verdict` for each flag still present, in one generation-checked write.
    private func record(_ flags: [SalientFlag], _ verdict: NudgeVerdict, callID: Int64?, context: JobContext) throws {
        guard !flags.isEmpty else { return }
        let store = NudgeDecisionStore(db)
        try DataGeneration.write(db, expected: context.generation) { d in
            for flag in flags {
                guard let id = flag.id,
                      try Bool.fetchOne(d, sql: "SELECT 1 FROM salient_flags WHERE id = ?", arguments: [id]) ?? false
                else { continue }
                try store.record(NudgeDecision(flagID: id, decision: verdict, flagLastSeenAt: flag.lastSeenAt,
                                               decidedAt: context.now, llmCallID: callID), in: d)
            }
        }
    }

    // MARK: - Evidence

    static let task = "Write one short nudge (at most 280 characters) that helps the user act on this item now. If it is someone else's request, say whose it is."

    /// The clock and one line per candidate, prefixed with its id. Quotes are left out: a quote may
    /// come from a snapshot excluded since, and triage does not need it.
    static func triageEvidence(_ flags: [SalientFlag], now: Date, calendar: Calendar) -> ProactiveEvidence {
        let b = BriefEvidence.Builder(calendar: calendar)
        let lines = flags.compactMap { f in
            f.id.map { "flag_id \($0) · " + b.flagLine(f, now: now)
                + " · last seen \(ProactivePrompt.stamp(f.lastSeenAt, calendar: calendar))" }
        }
        return ProactiveEvidence(sections: [clock(now, calendar: calendar), EvidenceSection(title: "Items", lines: lines)])
    }

    /// The clock, the flag, its verified quote (neutrally labelled) and excerpts of its snapshots.
    static func writeEvidence(_ flag: SalientFlag, snapshots: [Snapshot], now: Date, calendar: Calendar) -> ProactiveEvidence {
        let b = BriefEvidence.Builder(calendar: calendar)
        // Neutral: `owner` is extracted from captured text, so the label never asserts that the
        // user wrote the quote (a planted "commitment" must not read as the user's own words).
        let terms = [flag.quote, flag.text, flag.person, flag.project].filter { !$0.isEmpty }
        return ProactiveEvidence(sections: [
            clock(now, calendar: calendar),
            EvidenceSection(title: "Item", lines: [b.flagLine(flag, now: now)]),
            EvidenceSection(title: "Quote captured from the screen", lines: ["“\(flag.quote)”"]),
            EvidenceSection(title: "Excerpts of the screens it was seen on",
                            lines: excerpts(snapshots, terms: terms, calendar: calendar)),
        ])
    }

    /// Up to 4 snapshots (in the given order), each an `app HH:mm: …excerpt…` line around the
    /// terms, `excerptChars` characters in all.
    static func excerpts(_ snapshots: [Snapshot], terms: [String], calendar: Calendar) -> [String] {
        let shown = Array(snapshots.prefix(maxExcerpts))
        guard !shown.isEmpty else { return [] }
        let share = excerptChars / shown.count
        return shown.compactMap { s in
            let head = "\(s.app) \(ProactivePrompt.stamp(s.capturedAt, calendar: calendar, format: "HH:mm")): "
            let room = share - head.count
            guard room > 40 else { return nil }
            let body = Excerpt.around(terms: terms, in: s.text, radius: (room - 2) / 2)
            return head + String(body.prefix(room))
        }
    }

    static func clock(_ now: Date, calendar: Calendar) -> EvidenceSection {
        EvidenceSection(title: "Clock", lines: ["Now: \(ProactivePrompt.stamp(now, calendar: calendar))",
                                                "Time zone: \(calendar.timeZone.identifier)"])
    }
}
