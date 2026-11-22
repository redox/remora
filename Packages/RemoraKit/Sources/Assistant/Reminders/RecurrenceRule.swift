import Foundation

public enum Weekday: String, Codable, Sendable, CaseIterable {
    case mo = "MO", tu = "TU", we = "WE", th = "TH", fr = "FR", sa = "SA", su = "SU"

    /// Index from Monday = 0 (ISO weeks).
    var isoIndex: Int { Weekday.allCases.firstIndex(of: self)! }
    /// `Calendar.component(.weekday)` value (Sunday = 1).
    var calendarWeekday: Int { (isoIndex + 1) % 7 + 1 }
    init(calendarWeekday w: Int) { self = Weekday.allCases[(w + 5) % 7] }
}

/// `unsupported` names a valid RRULE part Remora does not implement; `invalid` a malformed one.
/// The payload is the offending part (`FREQ=YEARLY`), never user text.
public enum RecurrenceError: Error, Equatable {
    case unsupported(String), invalid(String)
}

/// The RRULE subset reminders use: `FREQ` (daily, weekly, monthly), `INTERVAL`, `BYDAY` (no
/// ordinals; weekly only), `BYMONTHDAY` (monthly only; `-1` = last day), `BYHOUR`, `BYMINUTE`,
/// `COUNT`, `UNTIL`. Occurrences are computed in wall-clock local time of the calendar passed in,
/// so 09:00 stays 09:00 across DST changes and time-zone moves.
public struct RecurrenceRule: Codable, Sendable, Equatable {
    public enum Frequency: String, Codable, Sendable { case daily = "DAILY", weekly = "WEEKLY", monthly = "MONTHLY" }

    public var frequency: Frequency
    public var interval = 1
    public var byDay: [Weekday] = []
    /// 1…31, or -1 for the last day of the month.
    public var byMonthDay: [Int] = []
    public var hour: Int?
    public var minute: Int?
    public var count: Int?
    public var until: Date?

    public init(frequency: Frequency, interval: Int = 1, byDay: [Weekday] = [], byMonthDay: [Int] = [],
                hour: Int? = nil, minute: Int? = nil, count: Int? = nil, until: Date? = nil) {
        self.frequency = frequency; self.interval = interval; self.byDay = byDay; self.byMonthDay = byMonthDay
        self.hour = hour; self.minute = minute; self.count = count; self.until = until
    }

    // MARK: Parsing

    /// Parses an RRULE body (an optional `RRULE:` prefix is accepted). `UNTIL` is `yyyyMMdd`
    /// (end of that local day), `yyyyMMdd'T'HHmmss` (local) or the same with a trailing `Z` (UTC).
    public static func parse(_ s: String, calendar: Calendar) throws(RecurrenceError) -> RecurrenceRule {
        var body = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.uppercased().hasPrefix("RRULE:") { body.removeFirst(6) }
        var parts: [String: String] = [:]
        var order: [String] = []
        for raw in body.split(separator: ";", omittingEmptySubsequences: true) {
            let kv = raw.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2, !kv[1].isEmpty else { throw .invalid(String(raw)) }
            let key = kv[0].uppercased()
            guard parts[key] == nil else { throw .invalid(String(key)) }
            parts[key] = String(kv[1]); order.append(key)
        }
        let known: Set<String> = ["FREQ", "INTERVAL", "BYDAY", "BYMONTHDAY", "BYHOUR", "BYMINUTE", "COUNT", "UNTIL"]
        for key in order where !known.contains(key) { throw .unsupported("\(key)=\(parts[key]!)") }

        guard let f = parts["FREQ"] else { throw .invalid("FREQ") }
        guard let freq = Frequency(rawValue: f.uppercased()) else { throw .unsupported("FREQ=\(f)") }
        var r = RecurrenceRule(frequency: freq)

        func int(_ key: String, _ range: ClosedRange<Int>) throws(RecurrenceError) -> Int? {
            guard let v = parts[key] else { return nil }
            guard let n = Int(v), range.contains(n) else { throw .invalid("\(key)=\(v)") }
            return n
        }
        let maxInterval: Int
        switch freq { case .daily: maxInterval = 365; case .weekly: maxInterval = 52; case .monthly: maxInterval = 12 }
        r.interval = try int("INTERVAL", 1...maxInterval) ?? 1
        r.hour = try int("BYHOUR", 0...23)
        r.minute = try int("BYMINUTE", 0...59)
        r.count = try int("COUNT", 1...10_000)

        if let v = parts["BYDAY"] {
            guard freq == .weekly else { throw .unsupported("BYDAY=\(v)") }
            var days: [Weekday] = []
            for t in v.split(separator: ",", omittingEmptySubsequences: false) {
                let u = t.uppercased()
                guard let d = Weekday(rawValue: u) else {
                    if u.count > 2, Weekday(rawValue: String(u.suffix(2))) != nil { throw .unsupported("BYDAY=\(v)") }
                    throw .invalid("BYDAY=\(v)")
                }
                if !days.contains(d) { days.append(d) }
            }
            r.byDay = days
        }
        if let v = parts["BYMONTHDAY"] {
            guard freq == .monthly else { throw .unsupported("BYMONTHDAY=\(v)") }
            var days: [Int] = []
            for t in v.split(separator: ",", omittingEmptySubsequences: false) {
                guard let n = Int(t), n != 0, (-31...31).contains(n) else { throw .invalid("BYMONTHDAY=\(v)") }
                guard n > 0 || n == -1 else { throw .unsupported("BYMONTHDAY=\(v)") }
                if !days.contains(n) { days.append(n) }
            }
            r.byMonthDay = days
        }
        if let v = parts["UNTIL"] {
            guard parts["COUNT"] == nil else { throw .invalid("COUNT=\(parts["COUNT"]!);UNTIL") }
            guard let d = parseUntil(v, calendar: calendar) else { throw .invalid("UNTIL=\(v)") }
            r.until = d
        }
        return r
    }

    private static func parseUntil(_ v: String, calendar: Calendar) -> Date? {
        var s = v.uppercased()
        var cal = calendar
        if s.hasSuffix("Z") { s.removeLast(); cal.timeZone = TimeZone(identifier: "UTC")! }
        let digits = Set("0123456789")
        func num(_ a: Int, _ n: Int) -> Int? {
            let sub = s.dropFirst(a).prefix(n)
            return sub.count == n && sub.allSatisfy(digits.contains) ? Int(sub) : nil
        }
        guard let y = num(0, 4), let mo = num(4, 2), let d = num(6, 2) else { return nil }
        var c = DateComponents(year: y, month: mo, day: d)
        if s.count == 8 {
            c.hour = 23; c.minute = 59; c.second = 59
        } else if s.count == 15, s.dropFirst(8).first == "T", let h = num(9, 2), let mi = num(11, 2), let se = num(13, 2) {
            c.hour = h; c.minute = mi; c.second = se
        } else { return nil }
        guard let date = cal.date(from: c), cal.dateComponents([.year, .month, .day], from: date) == DateComponents(year: y, month: mo, day: d)
        else { return nil }
        return date
    }

    // MARK: Serialising

    /// The RRULE body, without the `RRULE:` prefix. `UNTIL` is written in UTC (`…Z`), which
    /// `parse` reads back to the same instant whatever the calendar.
    public var rrule: String {
        var p = ["FREQ=\(frequency.rawValue)"]
        if interval != 1 { p.append("INTERVAL=\(interval)") }
        if !byDay.isEmpty { p.append("BYDAY=" + byDay.map(\.rawValue).joined(separator: ",")) }
        if !byMonthDay.isEmpty { p.append("BYMONTHDAY=" + byMonthDay.map(String.init).joined(separator: ",")) }
        if let hour { p.append("BYHOUR=\(hour)") }
        if let minute { p.append("BYMINUTE=\(minute)") }
        if let count { p.append("COUNT=\(count)") }
        if let until {
            var c = Calendar(identifier: .gregorian)
            c.timeZone = TimeZone(identifier: "UTC")!
            let x = c.dateComponents([.year, .month, .day, .hour, .minute, .second], from: until)
            p.append(String(format: "UNTIL=%04d%02d%02dT%02d%02d%02dZ", x.year!, x.month!, x.day!, x.hour!, x.minute!, x.second!))
        }
        return p.joined(separator: ";")
    }

    // MARK: Occurrences

    /// The outcome of an occurrence search: a date, a rule that has really ended (`count` /
    /// `until`), or a scan that found nothing within its horizon (a rule that never matches, e.g.
    /// day 31 every 12 months from February). Callers must not treat `exhausted` as "ended".
    enum Occurrence: Equatable { case found(Date), ended, exhausted }

    /// How many days past `after` the scan may look. Scaled by INTERVAL so every rule `parse`
    /// accepts is found: the largest legitimate gap is a leap day every 12 months (8 years).
    var horizonDays: Int {
        switch frequency {
        case .daily: return 400 + interval
        case .weekly: return 400 + 7 * interval
        case .monthly: return 366 * 9 + 31 * 12 * interval
        }
    }

    /// The first occurrence strictly after `after`, never earlier than `anchor` (DTSTART); nil
    /// when the rule has ended (`count` / `until`) or never matches. See `nextOccurrence`.
    public func next(after: Date, anchor: Date, calendar: Calendar) -> Date? {
        if case .found(let d) = nextOccurrence(after: after, anchor: anchor, calendar: calendar) { return d }
        return nil
    }

    /// Day matching is calendar arithmetic on local days; the time of day is `hour`/`minute`
    /// (else the anchor's local time) placed on that day, and a nonexistent time (spring-forward
    /// gap) moves forward keeping the minutes (02:30 -> 03:30). A repeated time (fall back) is
    /// the first one only.
    func nextOccurrence(after: Date, anchor: Date, calendar: Calendar) -> Occurrence {
        let ac = calendar.dateComponents([.hour, .minute], from: anchor)
        let h = hour ?? ac.hour ?? 0
        let m = minute ?? (hour != nil ? 0 : ac.minute ?? 0)
        let anchorDay = calendar.startOfDay(for: anchor)
        let anchorFloor = Date(timeIntervalSinceReferenceDate: (anchor.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
        let startAfter = max(after, anchorFloor.addingTimeInterval(-1))

        // With COUNT the occurrences must be counted from the anchor; otherwise start near `after`.
        var n = 0
        if count == nil {
            let d = calendar.dateComponents([.day], from: anchorDay, to: calendar.startOfDay(for: startAfter)).day ?? 0
            n = max(0, d - 1)
        }
        let anchorWeekday = Weekday(calendarWeekday: calendar.component(.weekday, from: anchor))
        let anchorMonthDay = calendar.component(.day, from: anchor)
        let anchorMonthIndex = monthIndex(anchor, calendar)
        let weekdays = byDay.isEmpty ? [anchorWeekday] : byDay
        let monthDays = byMonthDay.isEmpty ? [anchorMonthDay] : byMonthDay

        var seen = 0
        var daysPastAfter = 0
        let horizon = horizonDays
        while daysPastAfter <= horizon {
            guard let day = calendar.date(byAdding: .day, value: n, to: anchorDay) else { return .exhausted }
            if day > after { daysPastAfter += 1 }
            if let u = until, day > u { return .ended }
            if matches(day: day, n: n, anchorDay: anchorDay, anchorWeekday: anchorWeekday, anchorMonthIndex: anchorMonthIndex,
                       weekdays: weekdays, monthDays: monthDays, calendar: calendar),
               let occ = time(on: day, hour: h, minute: m, calendar: calendar), occ >= anchorFloor {
                seen += 1
                if let c = count, seen > c { return .ended }
                if let u = until, occ > u { return .ended }
                if occ > after { return .found(occ) }
            }
            n += 1
        }
        return .exhausted
    }

    private func monthIndex(_ d: Date, _ cal: Calendar) -> Int {
        let c = cal.dateComponents([.year, .month], from: d)
        return c.year! * 12 + c.month! - 1
    }

    private func matches(day: Date, n: Int, anchorDay: Date, anchorWeekday: Weekday, anchorMonthIndex: Int,
                         weekdays: [Weekday], monthDays: [Int], calendar: Calendar) -> Bool {
        switch frequency {
        case .daily:
            return n % interval == 0
        case .weekly:
            // ISO weeks: week index of day n counted from the anchor's Monday.
            let week = (n + anchorWeekday.isoIndex) / 7
            guard week % interval == 0 else { return false }
            return weekdays.contains(Weekday(calendarWeekday: calendar.component(.weekday, from: day)))
        case .monthly:
            guard (monthIndex(day, calendar) - anchorMonthIndex) % interval == 0 else { return false }
            let dom = calendar.component(.day, from: day)
            let length = calendar.range(of: .day, in: .month, for: day)?.count ?? 31
            return monthDays.contains { $0 == -1 ? dom == length : $0 == dom }
        }
    }

    private func time(on day: Date, hour: Int, minute: Int, calendar: Calendar) -> Date? {
        let start = calendar.startOfDay(for: day)
        guard let d = calendar.nextDate(after: start.addingTimeInterval(-1),
                                        matching: DateComponents(hour: hour, minute: minute, second: 0),
                                        matchingPolicy: .nextTimePreservingSmallerComponents),
              calendar.isDate(d, inSameDayAs: start) else { return nil }
        return d
    }

    // MARK: Describing

    /// "Every Friday at 17:00", "Every 2 weeks on Monday, Thursday at 09:30", "Every month on the
    /// last day at 08:00". Renders French when `locale` is French, English otherwise.
    public func describe(calendar: Calendar, locale: Locale) -> String {
        let fr = locale.language.languageCode?.identifier == "fr"
        func names(_ days: [Weekday]) -> String {
            var f = DateFormatter()
            f.locale = locale; f.calendar = calendar
            let symbols = f.weekdaySymbols ?? []
            f = DateFormatter()
            return days.map { symbols.indices.contains($0.calendarWeekday - 1) ? symbols[$0.calendarWeekday - 1] : $0.rawValue }
                .joined(separator: ", ")
        }
        var s: String
        switch frequency {
        case .daily:
            s = interval == 1 ? (fr ? "Chaque jour" : "Every day") : (fr ? "Tous les \(interval) jours" : "Every \(interval) days")
        case .weekly:
            if interval == 1, byDay.count == 1 {
                s = (fr ? "Chaque " : "Every ") + names(byDay)
            } else {
                s = interval == 1 ? (fr ? "Chaque semaine" : "Every week")
                                  : (fr ? "Toutes les \(interval) semaines" : "Every \(interval) weeks")
                if !byDay.isEmpty { s += (fr ? " le " : " on ") + names(byDay) }
            }
        case .monthly:
            s = interval == 1 ? (fr ? "Chaque mois" : "Every month") : (fr ? "Tous les \(interval) mois" : "Every \(interval) months")
            if !byMonthDay.isEmpty {
                let parts = byMonthDay.map { d -> String in
                    d == -1 ? (fr ? "dernier jour" : "last day") : (fr ? "jour \(d)" : "day \(d)")
                }
                s += (fr ? " le " : " on the ") + parts.joined(separator: ", ")
                if !fr, byMonthDay.contains(where: { $0 != -1 }) { s = s.replacingOccurrences(of: " on the day", with: " on day") }
            }
        }
        if let hour {
            s += (fr ? " à " : " at ") + String(format: "%02d:%02d", hour, minute ?? 0)
        }
        if let count { s += fr ? ", \(count) fois" : ", \(count) times" }
        if let until {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = calendar; f.timeZone = calendar.timeZone
            f.dateFormat = "yyyy-MM-dd"
            s += (fr ? ", jusqu'au " : ", until ") + f.string(from: until)
        }
        return s
    }
}
