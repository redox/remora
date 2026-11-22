import Foundation
import LLM
import Memory
import Storage
import os

/// The morning brief and evening wrap-up job (`morning_brief` / `evening_wrap`, period key = the
/// local day). It runs only inside its day's window (08:00–12:00, 16:00–24:00), so a Mac that
/// sleeps through 08:00 still gets the brief on wake until noon, and never after. Skip codes are
/// codes, never content.
public struct BriefRunner: JobRunner {
    /// Delivery grace past the window's end (pinned value).
    public static let grace: TimeInterval = 15 * 60
    /// ≤ 220 words.
    public static let maxChars = 1_600

    private let kind: BriefKind
    private let db: AppDatabase
    private let writer: VerifiedWriter
    private let inbox: ProactiveInbox
    private let enabled: @Sendable () -> Bool
    private let now: @Sendable () -> Date
    private static let log = Logger(subsystem: "dev.remora", category: "proactive")

    /// `now` is read again after the (slow) write, for the delivery deadline.
    public init(kind: BriefKind, db: AppDatabase, writer: VerifiedWriter, inbox: ProactiveInbox,
                enabled: @escaping @Sendable () -> Bool, now: @escaping @Sendable () -> Date = Date.init) {
        self.kind = kind; self.db = db; self.writer = writer; self.inbox = inbox; self.enabled = enabled; self.now = now
    }

    public func run(_ job: Job, context: JobContext) async throws -> JobOutcome {
        guard enabled() else { return .skipped("disabled") }
        let calendar = context.calendar
        let day = Self.day(of: job, calendar: calendar) ?? context.now
        let window = kind.window(day: day, calendar: calendar)
        guard context.now >= window.start, context.now < window.end else { return .skipped("window passed") }
        guard context.cloudAllowed else { return .skipped("cloud_denied") }
        let dayKey = PeriodKey.key(.day, for: window.start, calendar: calendar)
        let dedupeKey = Self.dedupeKey(kind, dayKey: dayKey)
        guard try !inbox.delivered(dedupeKey: dedupeKey) else { return .skipped("duplicate") }

        let evidence = try kind == .morning
            ? BriefEvidence.morning(db: db, now: context.now, calendar: calendar)
            : BriefEvidence.evening(db: db, now: context.now, calendar: calendar)
        guard !evidence.isEmpty else { return .skipped("no activity") }

        let result = try await writer.write(job: jobType, kind: inboxKind, evidence: evidence, task: task,
                                            maxChars: Self.maxChars, context: context)
        guard case .accepted(let text, let callIDs) = result else { return .skipped("unverified") }
        let deliveredAt = now()
        guard deliveredAt <= window.end.addingTimeInterval(Self.grace) else { return .skipped("window passed") }
        let stored = try await inbox.deliver(kind: inboxKind, title: title, body: text, dedupeKey: dedupeKey,
                                             callIDs: callIDs, expectedGeneration: context.generation,
                                             evidence: evidence.sources, at: deliveredAt)
        guard stored != nil else {
            // A duplicate raced us, proactive was turned off, or the evidence was forgotten meanwhile.
            if try inbox.delivered(dedupeKey: dedupeKey) { return .skipped("duplicate") }
            return enabled() ? .skipped("evidence changed") : .skipped("disabled")
        }
        Self.log.info("\(inboxKind.rawValue, privacy: .public) delivered")
        return .done
    }

    /// `morning_brief:<day>` / `evening_wrap:<day>`.
    public static func dedupeKey(_ kind: BriefKind, dayKey: String) -> String {
        "\(kind == .morning ? InboxKind.morningBrief.rawValue : InboxKind.eveningWrap.rawValue):\(dayKey)"
    }

    private var inboxKind: InboxKind { kind == .morning ? .morningBrief : .eveningWrap }
    private var jobType: JobType { kind == .morning ? .morningBrief : .eveningWrap }
    private var title: String { kind == .morning ? "Morning brief" : "Evening wrap-up" }
    private var task: String {
        kind == .morning
            ? "Write this morning's brief for the user from the evidence: what matters today, what is due, what is still open."
            : "Write this evening's wrap-up for the user from the evidence: what they did today, what got done, what is still open, where their time went."
    }

    /// The job's local day: its period start (the window start), else its `yyyy-MM-dd` key.
    static func day(of job: Job, calendar: Calendar) -> Date? {
        if let start = job.periodStart { return start }
        let parts = job.periodKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }
}
