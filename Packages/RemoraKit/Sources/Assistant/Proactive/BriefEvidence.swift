import Capture
import Foundation
import GRDB
import Memory
import Retrieval
import Storage

public enum BriefKind: Sendable, Equatable {
    case morning, evening

    /// Morning 08:00–12:00, evening 16:00–24:00 of `day`'s local date (pinned values).
    public func window(day: Date, calendar: Calendar) -> DateInterval {
        let dayInterval = calendar.dateInterval(of: .day, for: day) ?? DateInterval(start: day, duration: 86_400)
        func at(_ hour: Int) -> Date {
            calendar.date(bySettingHour: hour, minute: 0, second: 0, of: dayInterval.start, matchingPolicy: .nextTime)
                ?? dayInterval.start.addingTimeInterval(Double(hour) * 3_600)
        }
        switch self {
        case .morning: return DateInterval(start: at(8), end: at(12))
        case .evening: return DateInterval(start: at(16), end: max(at(16), dayInterval.end))
        }
    }
}

/// The evidence of a morning brief or an evening wrap, read in one transaction and filtered by the
/// exclusions loaded fresh for this run (`SnapshotPolicy.current`, `.denyAll` when they cannot be
/// loaded): chronicles and flags through `DerivedPolicy.filter`, working memory through
/// `requiringLiveEvidence`, the time ledger through `SnapshotPolicy.allows(app:domain:)` (F-58).
/// Empty when no snapshot was captured in the last 72 h, or when nothing but the clock is left.
public enum BriefEvidence {
    public static let recentActivity: TimeInterval = 72 * 3_600
    static let maxOpen = 8
    static let maxFocus = 5
    static let maxProjects = 5
    static let lookBackDays = 3
    static let flagRows = 200

    public static func morning(db: AppDatabase, now: Date, calendar: Calendar) throws -> ProactiveEvidence {
        let policy = SnapshotPolicy.current(db)
        return try db.reader.read { d in
            guard try recent(now: now, in: d) else { return ProactiveEvidence(sections: []) }
            var b = Builder(calendar: calendar)
            let today = day(now, calendar)

            // Yesterday, else the last active day within 3 days.
            for back in 1...lookBackDays {
                guard let start = calendar.date(byAdding: .day, value: -back, to: today.start),
                      let span = calendar.dateInterval(of: .day, for: start) else { continue }
                let lines = try dayLines(span, policy: policy, builder: &b, in: d)
                guard !lines.isEmpty else { continue }
                let title = back == 1 ? "Yesterday"
                    : "Last active day (\(ProactivePrompt.stamp(span.start, calendar: calendar, format: "EEEE yyyy-MM-dd")))"
                b.sections.append(EvidenceSection(title: title, lines: lines))
                break
            }

            let flags = try openFlags(policy: policy, in: d)
            let userOwned = flags.filter { $0.owner == .user && ($0.kind == .commitment || $0.kind == .todo) }
            // Due today: events due today (anyone's: a meeting is the user's to attend) and the
            // user's own flags due today, plus the user's commitments and todos already overdue.
            // Someone else's non-event flags (their email, their commitment) are left out: they are
            // not the user's to do, and listing them would read as a task for the user.
            let due = flags.filter { f in
                guard let at = f.dueAt else { return false }
                if today.contains(at) { return f.kind == .event || f.owner == .user }
                return at < now && userOwned.contains(f)
            }
            b.add("Due today", due.map { b.flagLine($0, now: now) }, sources: due)
            let open = Array(userOwned.sorted(by: dueFirst).prefix(maxOpen))
            b.add("Open commitments", open.map { b.flagLine($0, now: now) }, sources: open)

            let focus = try focus(db: db, now: now, policy: policy, in: d)
            b.add("Current focus", focus.map(\.text))
            b.track(focus.compactMap { i in i.id.map { EvidenceSource(table: "working_memory", id: $0, snapshotIDs: i.snapshotIDs) } })
            return b.result(now: now)
        }
    }

    public static func evening(db: AppDatabase, now: Date, calendar: Calendar) throws -> ProactiveEvidence {
        let policy = SnapshotPolicy.current(db)
        return try db.reader.read { d in
            guard try recent(now: now, in: d) else { return ProactiveEvidence(sections: []) }
            var b = Builder(calendar: calendar)
            let today = day(now, calendar)
            let tomorrowEnd = calendar.date(byAdding: .day, value: 1, to: today.end) ?? today.end.addingTimeInterval(86_400)

            let hours = try DerivedPolicy.filter(
                try ChronicleStore(db).chronicles(.hour, within: DateInterval(start: today.start, end: max(today.start, now)), in: d)
                    .filter { !$0.isDirty },
                ids: \.snapshotIDs, policy: policy, in: d)
            b.add("Today", hours.map { b.hourLine($0) }, sources: hours)

            let closed = try DerivedPolicy.filter(try SalientFlag.fetchAll(d, sql: """
                SELECT * FROM salient_flags WHERE status = 'done' AND closed_at >= ? AND closed_at < ?
                ORDER BY closed_at, id LIMIT ?
                """, arguments: [today.start, today.end, flagRows]), ids: \.snapshotIDs, policy: policy, in: d)
            b.add("Done today", closed.map { b.flagLine($0, now: now) }, sources: closed)

            let open = try openFlags(policy: policy, in: d).filter { f in
                f.owner == .user && (f.kind == .commitment || f.kind == .todo)
                    && (today.contains(f.lastSeenAt) || (f.dueAt.map { $0 < tomorrowEnd } ?? false))
            }.sorted(by: dueFirst)
            b.add("Still open", open.map { b.flagLine($0, now: now) }, sources: open)

            let rows = try TimeLedgerStore(db).rows(from: today.start, to: today.end, in: d)
            let projects = RollupPipeline.projectTime(rows, policy: policy).prefix(maxProjects)
            b.add("Time", projects.map { "\($0.name) · \(duration($0.seconds))" })
            return b.result(now: now)
        }
    }

    // MARK: - Reads (inside the caller's read)

    static func recent(now: Date, in d: Database) throws -> Bool {
        try Bool.fetchOne(d, sql: "SELECT 1 FROM snapshots WHERE captured_at >= ? AND captured_at <= ? LIMIT 1",
                          arguments: [now.addingTimeInterval(-recentActivity), now]) ?? false
    }

    /// The day's chronicle, else its hour summaries; filtered. A dirty chronicle is never used:
    /// a forget (`Provenance.cascade`) leaves a partly forgotten summary in place and only marks it
    /// dirty until it is rebuilt, so a dirty day falls back to its clean hours, and dirty hours
    /// are dropped.
    static func dayLines(_ span: DateInterval, policy: CapturePolicy, builder b: inout Builder, in d: Database) throws -> [String] {
        let key = PeriodKey.key(.day, for: span.start, calendar: b.calendar)
        if let c = try Chronicle.fetchOne(d, sql: "SELECT * FROM chronicle WHERE level = 'day' AND period_key = ?",
                                          arguments: [key]),
           !c.isDirty,
           let kept = try DerivedPolicy.filter([c], ids: \.snapshotIDs, policy: policy, in: d).first,
           !kept.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            b.track([kept])
            return [kept.summary]
        }
        let hours = try DerivedPolicy.filter(try Chronicle.fetchAll(d, sql: """
            SELECT * FROM chronicle WHERE level = 'hour' AND period_start >= ? AND period_end <= ?
            ORDER BY period_start, id
            """, arguments: [span.start, span.end]).filter { !$0.isDirty }, ids: \.snapshotIDs, policy: policy, in: d)
            .filter { !$0.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        b.track(hours)
        return hours.map { b.hourLine($0) }
    }

    static func openFlags(policy: CapturePolicy, in d: Database) throws -> [SalientFlag] {
        try DerivedPolicy.filter(try SalientFlag.fetchAll(d, sql: """
            SELECT * FROM salient_flags WHERE status = 'open'
            ORDER BY due_at IS NULL, due_at, last_seen_at DESC, id DESC LIMIT ?
            """, arguments: [flagRows]), ids: \.snapshotIDs, policy: policy, in: d)
    }

    static func focus(db: AppDatabase, now: Date, policy: CapturePolicy, in d: Database) throws -> [WorkingMemoryItem] {
        let top = try WorkingMemoryStore(db).top(maxFocus * 4, now: now, in: d)
        return Array(try DerivedPolicy.requiringLiveEvidence(top, ids: \.snapshotIDs, policy: policy, in: d).prefix(maxFocus))
    }

    /// Dated first (soonest), then the most recently seen.
    static func dueFirst(_ a: SalientFlag, _ b: SalientFlag) -> Bool {
        switch (a.dueAt, b.dueAt) {
        case let (x?, y?) where x != y: return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        default: return a.lastSeenAt > b.lastSeenAt
        }
    }

    static func day(_ d: Date, _ calendar: Calendar) -> DateInterval {
        calendar.dateInterval(of: .day, for: d) ?? DateInterval(start: d, duration: 86_400)
    }

    static func duration(_ seconds: Double) -> String {
        let m = Int((seconds / 60).rounded())
        if m < 1 { return "under 1 min" }
        return m < 60 ? "\(m) min" : (m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min")
    }

    // MARK: - Builder

    struct Builder {
        let calendar: Calendar
        var sections: [EvidenceSection] = []
        var sources: [EvidenceSource] = []

        mutating func add(_ title: String, _ lines: [String]) {
            if !lines.isEmpty { sections.append(EvidenceSection(title: title, lines: lines)) }
        }

        mutating func add(_ title: String, _ lines: [String], sources rows: [SalientFlag]) {
            track(rows.compactMap { f in f.id.map { EvidenceSource(table: "salient_flags", id: $0, snapshotIDs: f.snapshotIDs) } })
            if !lines.isEmpty { sections.append(EvidenceSection(title: title, lines: lines)) }
        }

        mutating func add(_ title: String, _ lines: [String], sources rows: [Chronicle]) {
            track(rows)
            if !lines.isEmpty { sections.append(EvidenceSection(title: title, lines: lines)) }
        }

        mutating func track(_ rows: [Chronicle]) {
            track(rows.compactMap { c in c.id.map { EvidenceSource(table: "chronicle", id: $0, snapshotIDs: c.snapshotIDs) } })
        }

        mutating func track(_ s: [EvidenceSource]) {
            for source in s where !sources.contains(where: { $0.table == source.table && $0.id == source.id }) {
                sources.append(source)
            }
        }

        func hourLine(_ c: Chronicle) -> String {
            "\(ProactivePrompt.stamp(c.periodStart, calendar: calendar, format: "HH:mm"))–"
                + "\(ProactivePrompt.stamp(c.periodEnd, calendar: calendar, format: "HH:mm")) \(c.summary)"
        }

        /// `kind (whose) · “text” · with person · project · due …` (overdue when past). The text
        /// is captured from the screen, so it is quoted and attributed: someone else's request
        /// ("Wire the money today") reads as theirs, never as an instruction to pass on.
        func flagLine(_ f: SalientFlag, now: Date) -> String {
            // `owner` is extracted from captured text: never assert the user wrote it.
            let owner = f.owner == .user
                ? "\(f.kind.rawValue) (captured from the screen)"
                : "\(f.kind.rawValue) from \(f.person.isEmpty ? "someone else" : f.person) (their words, not the user's)"
            var parts = [owner, "“\(f.text)”"]
            if f.owner == .user, !f.person.isEmpty { parts.append("with \(f.person)") }
            if !f.project.isEmpty { parts.append(f.project) }
            if let due = f.dueAt {
                let stamp = ProactivePrompt.stamp(due, calendar: calendar, format: "EEEE yyyy-MM-dd HH:mm")
                parts.append(due < now && f.status == .open ? "overdue since \(stamp)" : "due \(stamp)")
            }
            if f.status == .done, let closed = f.closedAt {
                parts.append("done at \(ProactivePrompt.stamp(closed, calendar: calendar, format: "HH:mm"))")
            }
            return parts.joined(separator: " · ")
        }

        /// Clock first; empty when nothing but the clock would be left.
        func result(now: Date) -> ProactiveEvidence {
            guard !sections.isEmpty else { return ProactiveEvidence(sections: []) }
            let clock = EvidenceSection(title: "Clock", lines: [
                "Now: \(ProactivePrompt.stamp(now, calendar: calendar))",
                "Time zone: \(calendar.timeZone.identifier)",
            ])
            return ProactiveEvidence(sections: [clock] + sections, sources: sources)
        }
    }
}
