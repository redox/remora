import Foundation
import GRDB
import Storage

public enum ReminderSchedule: Sendable, Equatable {
    case once(Date)
    case recurring(RecurrenceRule, anchor: Date)
    case interval(seconds: Int, anchor: Date)
}

public struct ReminderDraft: Sendable, Equatable {
    public var text: String
    public var action: ReminderAction
    public var schedule: ReminderSchedule
    public var origin: ReminderOrigin
    public init(text: String, action: ReminderAction, schedule: ReminderSchedule, origin: ReminderOrigin) {
        self.text = text; self.action = action; self.schedule = schedule; self.origin = origin
    }
}

public enum ReminderError: Error, Equatable, Sendable {
    case inPast, tooFar, intervalTooShort(minimumMinutes: Int), tooMany, emptyText, notFound, noFutureOccurrence
}

public struct Firing: Sendable, Equatable {
    public var reminder: Reminder
    public var scheduledFor: Date
    public var late: Bool
    public init(reminder: Reminder, scheduledFor: Date, late: Bool) {
        self.reminder = reminder; self.scheduledFor = scheduledFor; self.late = late
    }
}

/// Creates, cancels and fires reminders. All times are computed in the calendar returned by
/// `calendar()` at the moment of use (production: `MemoryCalendar.local`, auto-updating), so a
/// recurring reminder for 09:00 stays at 09:00 local after DST or travel. Reminder texts are
/// user text: never logged.
public actor ReminderEngine {
    public static let maxActive = 50
    public static let lateAfter: TimeInterval = 120
    public static let maxAheadYears = 2
    /// Shortest repeat interval, in minutes, of a `notify` reminder…
    public static let minNotifyIntervalMinutes = 5
    /// …and of a `prompt` reminder (each firing is a model call).
    public static let minPromptIntervalMinutes = 60

    private let store: ReminderStore
    private let db: AppDatabase
    private let calendar: @Sendable () -> Calendar
    private let now: @Sendable () -> Date

    public init(store: ReminderStore, db: AppDatabase, calendar: @escaping @Sendable () -> Calendar,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store; self.db = db; self.calendar = calendar; self.now = now
    }

    // MARK: API

    /// With `expected`, the insert runs in `DataGeneration.write(expected:)`, so a reminder
    /// confirmed after a delete-all is refused (`DataGeneration.Stale`).
    public func create(_ d: ReminderDraft, expected: Int? = nil) throws -> Reminder {
        let cal = calendar()
        let t = now()
        let text = d.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ReminderError.emptyText }

        let limit = cal.date(byAdding: .year, value: Self.maxAheadYears, to: t) ?? .distantFuture
        var row = Reminder(text: text, action: d.action, kind: .once, anchorAt: t, timeZone: cal.timeZone.identifier,
                           createdBy: d.origin, createdAt: t)
        switch d.schedule {
        case .once(let date):
            guard date > t else { throw ReminderError.inPast }
            row.kind = .once; row.anchorAt = date; row.nextFireAt = date
        case .interval(let seconds, let anchor):
            let minimum = d.action == .prompt ? Self.minPromptIntervalMinutes : Self.minNotifyIntervalMinutes
            guard seconds >= minimum * 60 else { throw ReminderError.intervalTooShort(minimumMinutes: minimum) }
            row.kind = .interval; row.anchorAt = anchor; row.intervalSeconds = seconds
            row.nextFireAt = Self.intervalNext(anchor: anchor, seconds: seconds, after: t)
        case .recurring(var rule, let anchor):
            rule = Self.stamped(rule, anchor: anchor, calendar: cal)
            row.kind = .recurring; row.anchorAt = anchor; row.rrule = rule.rrule
            guard let first = rule.next(after: t, anchor: anchor, calendar: cal) else { throw ReminderError.noFutureOccurrence }
            row.nextFireAt = first
        }
        if let first = row.nextFireAt, first > limit { throw ReminderError.tooFar }
        return try write(expected) { dbc in
            guard try store.active(in: dbc).count < Self.maxActive else { throw ReminderError.tooMany }
            return try store.insert(row, in: dbc)
        }
    }

    public func cancel(_ id: Int64, expected: Int? = nil) throws -> Reminder {
        try write(expected) { d in
            guard var r = try store.get(id, in: d) else { throw ReminderError.notFound }
            if r.status == .done { return r }
            r.status = .cancelled
            try store.update(r, in: d)
            return r
        }
    }

    /// Cancels the reminder only if it is active; nil (nothing written) otherwise. The chat's
    /// `cancel_reminder` uses it, so its undo (`reactivate`) never revives one that was not active.
    public func cancelIfActive(_ id: Int64, expected: Int? = nil) throws -> Reminder? {
        try write(expected) { d in
            guard var r = try store.get(id, in: d), r.status == .active else { return nil }
            r.status = .cancelled
            try store.update(r, in: d)
            return r
        }
    }

    /// Makes a cancelled or finished reminder active again, recomputing its next occurrence.
    public func reactivate(_ id: Int64, expected: Int? = nil) throws -> Reminder {
        let cal = calendar(), t = now()
        return try write(expected) { d in
            guard var r = try store.get(id, in: d) else { throw ReminderError.notFound }
            if r.status == .active { return r }
            guard try store.active(in: d).count < Self.maxActive else { throw ReminderError.tooMany }
            switch r.kind {
            case .once:
                guard r.anchorAt > t else { throw ReminderError.inPast }
                r.nextFireAt = r.anchorAt
            case .interval:
                guard let s = r.intervalSeconds, s > 0 else { throw ReminderError.noFutureOccurrence }
                r.nextFireAt = Self.intervalNext(anchor: r.anchorAt, seconds: s, after: t)
            case .recurring:
                guard let rule = Self.rule(of: r, calendar: cal),
                      let n = rule.next(after: t, anchor: r.anchorAt, calendar: cal) else { throw ReminderError.noFutureOccurrence }
                r.nextFireAt = n
            }
            r.timeZone = cal.timeZone.identifier
            r.status = .active
            try store.update(r, in: d)
            return r
        }
    }

    public func list() throws -> [Reminder] { try store.active() }

    /// The earliest next firing, after realigning recurring reminders to the current time zone.
    public func nextFireAt() throws -> Date? {
        try db.writer.write { d in
            try realign(in: d)
            return try Date.fetchOne(d, sql: "SELECT min(next_fire_at) FROM reminders WHERE status = 'active'")
        }
    }

    /// Fires every due reminder once (its latest missed occurrence), in one transaction.
    public func fireDue() throws -> [Firing] {
        try fireDue(onFiring: { _, _ in })
    }

    /// Like `fireDue()`, and runs `onFiring` for each firing inside the same transaction, after the
    /// reminder row is updated, so whatever it stores commits together with the firing (or not at
    /// all). Only `in d:` writes may be used in it (GRDB writes are not reentrant).
    public func fireDue(onFiring: @Sendable (Firing, Database) throws -> Void) throws -> [Firing] {
        let cal = calendar(), t = now()
        return try db.writer.write { d in
            try realign(in: d, calendar: cal, now: t)
            var out: [Firing] = []
            for var r in try store.due(at: t, in: d) {
                guard let due = r.nextFireAt else { continue }
                var scheduled = due
                var upcoming: Date?
                var keepActive = false
                switch r.kind {
                case .once:
                    upcoming = nil
                case .interval:
                    let s = r.intervalSeconds ?? 0
                    guard s > 0 else { r.status = .done; r.nextFireAt = nil; try store.update(r, in: d); continue }
                    let k = max(0, Int((t.timeIntervalSince(r.anchorAt) / Double(s)).rounded(.down)))
                    scheduled = max(due, r.anchorAt.addingTimeInterval(Double(k * s)))
                    upcoming = scheduled.addingTimeInterval(Double(s))
                case .recurring:
                    guard let rule = Self.rule(of: r, calendar: cal) else { r.status = .done; r.nextFireAt = nil; try store.update(r, in: d); continue }
                    var following = rule.nextOccurrence(after: scheduled, anchor: r.anchorAt, calendar: cal)
                    while case .found(let f) = following, f <= t {
                        scheduled = f
                        following = rule.nextOccurrence(after: f, anchor: r.anchorAt, calendar: cal)
                    }
                    switch following {
                    case .found(let f): upcoming = f
                    case .ended: upcoming = nil
                    case .exhausted: upcoming = nil; keepActive = true // never mark a still-valid rule done
                    }
                }
                r.fireCount += 1
                r.lastFiredAt = t
                r.nextFireAt = upcoming
                if upcoming == nil, !keepActive { r.status = .done }
                try store.update(r, in: d)
                let firing = Firing(reminder: r, scheduledFor: scheduled, late: t.timeIntervalSince(scheduled) > Self.lateAfter)
                try onFiring(firing, d)
                out.append(firing)
            }
            return out
        }
    }

    // MARK: Helpers

    /// A plain write, or a generation-checked one when `expected` is given.
    private func write<T>(_ expected: Int?, _ body: (Database) throws -> T) throws -> T {
        if let expected { return try DataGeneration.write(db, expected: expected, body) }
        return try db.writer.write(body)
    }

    private func realign(in d: Database) throws { try realign(in: d, calendar: calendar(), now: now()) }

    /// Recurring reminders created in another time zone keep their wall-clock time: recompute
    /// `next_fire_at` from the rule in the current zone.
    private func realign(in d: Database, calendar cal: Calendar, now t: Date) throws {
        for var r in try store.active(in: d) where r.kind == .recurring && r.timeZone != cal.timeZone.identifier {
            r.timeZone = cal.timeZone.identifier
            if let rule = Self.rule(of: r, calendar: cal) {
                // Keep a pending occurrence due now: search from just before it.
                let from = min(t, r.nextFireAt ?? t)
                switch rule.nextOccurrence(after: from.addingTimeInterval(-1), anchor: r.anchorAt, calendar: cal) {
                case .found(let f): r.nextFireAt = f
                case .ended: r.nextFireAt = nil; r.status = .done
                case .exhausted: r.nextFireAt = nil
                }
            }
            try store.update(r, in: d)
        }
    }

    private static func rule(of r: Reminder, calendar: Calendar) -> RecurrenceRule? {
        guard let s = r.rrule else { return nil }
        return try? RecurrenceRule.parse(s, calendar: calendar)
    }

    /// Fixes the rule's wall-clock fields from the anchor in the creating calendar, so a later
    /// time-zone change keeps the local time and weekday/day-of-month the user meant.
    static func stamped(_ rule: RecurrenceRule, anchor: Date, calendar: Calendar) -> RecurrenceRule {
        var r = rule
        let c = calendar.dateComponents([.hour, .minute, .weekday, .day], from: anchor)
        if r.hour == nil { r.hour = c.hour; if r.minute == nil { r.minute = c.minute } } else if r.minute == nil { r.minute = 0 }
        if r.frequency == .weekly, r.byDay.isEmpty { r.byDay = [Weekday(calendarWeekday: c.weekday!)] }
        if r.frequency == .monthly, r.byMonthDay.isEmpty { r.byMonthDay = [c.day!] }
        return r
    }

    /// The first `anchor + k·seconds` (k ≥ 0) strictly after `t`.
    static func intervalNext(anchor: Date, seconds: Int, after t: Date) -> Date {
        guard t >= anchor else { return anchor }
        let k = Int((t.timeIntervalSince(anchor) / Double(seconds)).rounded(.down)) + 1
        return anchor.addingTimeInterval(Double(k * seconds))
    }
}
