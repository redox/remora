import Foundation
import GRDB
import Storage
import os

/// Matches activity against the user's time rules (F-66: text compared through `TextFold`).
public enum TimeRuleMatcher {
    /// The project of the first rule (in id order) whose every set field matches: `app` equal
    /// (folded), `domain` equal or a subdomain of it, `titleContains` contained in the title
    /// (folded: case, accents, quotes). A rule with no usable field matches nothing.
    public static func project(app: String, domain: String?, title: String?, rules: [TimeRule]) -> String? {
        rules.sorted { ($0.id ?? .max) < ($1.id ?? .max) }.first { matches($0, app: app, domain: domain, title: title) }?
            .project
    }

    static func matches(_ r: TimeRule, app: String, domain: String?, title: String?) -> Bool {
        let ruleApp = usable(r.app), ruleDomain = usable(r.domain), ruleTitle = usable(r.titleContains)
        guard ruleApp != nil || ruleDomain != nil || ruleTitle != nil else { return false }
        if let ruleApp, TextFold.fold(ruleApp) != TextFold.fold(app) { return false }
        if let ruleDomain, !domainMatches(domain, ruleDomain) { return false }
        if let ruleTitle {
            guard let title, TextFold.fold(title).contains(TextFold.fold(ruleTitle)) else { return false }
        }
        return true
    }

    /// `domain` equals `pattern` or is a subdomain of it ("gist.github.com" for "github.com").
    static func domainMatches(_ domain: String?, _ pattern: String) -> Bool {
        guard let domain = usable(domain) else { return false }
        let d = host(domain), p = host(pattern)
        return !p.isEmpty && (d == p || d.hasSuffix("." + p))
    }

    private static func host(_ s: String) -> String {
        TextFold.fold(s).trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private static func usable(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }
}

/// Builds an hour's time-ledger rows from its focus events.
public enum TimeLedgerBuilder {
    /// The project of time no rule or attribution claims.
    public static let unassigned = "Unassigned"

    /// Seconds clipped to `hour` and summed per (project, app, domain), sorted by those keys.
    /// Project = the first matching user rule, else the first attribution whose `apps` holds the
    /// app (folded) or whose `domains` holds the domain (or a parent domain), else `Unassigned`.
    public static func rows(events: [ActivityEvent], hour: DateInterval, rules: [TimeRule],
                            attribution: [ProjectShare]) -> [TimeLedgerRow] {
        struct Key: Hashable { var project: String; var app: String; var domain: String }
        var seconds: [Key: Double] = [:]
        for e in events {
            let clipped = min(e.endedAt, hour.end).timeIntervalSince(max(e.startedAt, hour.start))
            guard clipped > 0 else { continue }
            let domain = e.domain ?? ""
            let project = TimeRuleMatcher.project(app: e.app, domain: e.domain, title: e.windowTitle, rules: rules)
                ?? attributed(app: e.app, domain: domain, attribution: attribution)
                ?? unassigned
            seconds[Key(project: project, app: e.app, domain: domain), default: 0] += clipped
        }
        return seconds.sorted { ($0.key.project, $0.key.app, $0.key.domain) < ($1.key.project, $1.key.app, $1.key.domain) }
            .map { TimeLedgerRow(hourStart: hour.start, project: $0.key.project, app: $0.key.app, domain: $0.key.domain,
                                 seconds: $0.value) }
    }

    private static func attributed(app: String, domain: String, attribution: [ProjectShare]) -> String? {
        let folded = TextFold.fold(app)
        return attribution.first { p in
            p.apps.contains { TextFold.fold($0) == folded }
                || (!domain.isEmpty && p.domains.contains { TimeRuleMatcher.domainMatches(domain, $0) })
        }.flatMap { TextFold.key($0.name).isEmpty ? nil : $0.name }
    }
}

/// Runs a `time_ledger` job (no LLM): replaces one closed hour's ledger rows. Attribution comes
/// from the hour chronicle whose span contains the hour (a merged sparse span is keyed by its
/// first hour, F-32). Idempotent; re-run when the hour chronicle lands (`HourPipeline` requeues
/// it). The ledger is local: it records excluded apps by name, and nothing here builds a prompt
/// (F-58).
public struct TimeLedgerPipeline: JobRunner {
    private let db: AppDatabase
    private static let log = Logger(subsystem: "dev.remora", category: "memory")

    public init(db: AppDatabase) { self.db = db }

    public func run(_ job: Job, context: JobContext) async throws -> JobOutcome {
        guard job.kind == .timeLedger else { return .skipped("wrong_kind") }
        guard let start = job.periodStart, let end = job.periodEnd, end > start else { return .skipped("no_period") }
        let hour = DateInterval(start: start, end: end)
        let events = try ActivityStore(db).events(overlapping: hour)
        let rules = try TimeLedgerStore(db).rules()
        let attribution = try ChronicleStore(db).chronicle(.hour, containing: hour)?.metadata.projects ?? []
        let rows = TimeLedgerBuilder.rows(events: events, hour: hour, rules: rules, attribution: attribution)
        let store = TimeLedgerStore(db)
        try DataGeneration.write(db, expected: context.generation) { d in
            try store.replace(hour: hour.start, rows: rows, in: d)
        }
        Self.log.info("time ledger \(job.periodKey, privacy: .public): \(rows.count, privacy: .public) rows, attribution \(!attribution.isEmpty, privacy: .public)")
        return .done
    }
}
