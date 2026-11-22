import Foundation
import Storage

/// Period keys and intervals for the memory pipeline (plan 4 pinned values). Everything is
/// computed from the `calendar` it is given (production: ISO 8601 in the local time zone).
///
/// - hour `yyyy-MM-dd'T'HH±hhmm`, the UTC offset keeps the repeated DST hour distinct;
/// - day `yyyy-MM-dd`, ISO week `YYYY-Www`, month `yyyy-MM`, year `yyyy`.
public enum PeriodKey {
    /// The production calendar (`MemoryCalendar.local`: ISO 8601, local time zone, auto-updating).
    public static var localCalendar: Calendar { MemoryCalendar.local }

    public static func key(_ level: ChronicleLevel, for date: Date, calendar: Calendar) -> String {
        switch level {
        case .hour: return hourKey(date, calendar: calendar)
        case .day:
            let c = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        case .week:
            let c = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            return String(format: "%04d-W%02d", c.yearForWeekOfYear ?? 0, c.weekOfYear ?? 0)
        case .month:
            let c = calendar.dateComponents([.year, .month], from: date)
            return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
        case .year:
            return String(format: "%04d", calendar.component(.year, from: date))
        }
    }

    /// The hour / day / ISO week / month / year containing `date`.
    public static func interval(_ level: ChronicleLevel, containing date: Date, calendar: Calendar) -> DateInterval {
        calendar.dateInterval(of: level.calendarComponent, for: date) ?? DateInterval(start: date, duration: 3_600)
    }

    /// Hour key + `:mm` floored to 10 minutes.
    public static func workingMemorySlot(_ d: Date, calendar: Calendar) -> String {
        let minute = calendar.component(.minute, from: d) / 10 * 10
        return hourKey(d, calendar: calendar) + String(format: ":%02d", minute)
    }

    /// The 10-minute working-memory slot containing `d`.
    public static func workingMemoryInterval(_ d: Date, calendar: Calendar) -> DateInterval {
        let hour = interval(.hour, containing: d, calendar: calendar)
        let minute = calendar.component(.minute, from: d) / 10 * 10
        let start = hour.start.addingTimeInterval(Double(minute) * 60)
        return DateInterval(start: start, duration: 600)
    }

    /// The hour key of the start of the local 3-hour slot (00, 03, … 21) containing `d`.
    public static func wikiSlot(_ d: Date, calendar: Calendar) -> String {
        hourKey(wikiSlotInterval(d, calendar: calendar).start, calendar: calendar)
    }

    /// The local 3-hour slot (00, 03, … 21 o'clock) containing `d`. Both boundaries come from calendar
    /// hour components, so a DST day's slots (2 h or 4 h long in absolute time) still tile the day.
    public static func wikiSlotInterval(_ d: Date, calendar: Calendar) -> DateInterval {
        let slotHour = calendar.component(.hour, from: d) / 3 * 3
        let start = calendar.date(bySettingHour: slotHour, minute: 0, second: 0, of: d, matchingPolicy: .nextTime)
            ?? interval(.hour, containing: d, calendar: calendar).start
        let end: Date
        if slotHour + 3 < 24 {
            end = calendar.date(bySettingHour: slotHour + 3, minute: 0, second: 0, of: d, matchingPolicy: .nextTime)
                ?? start.addingTimeInterval(10_800)
        } else {
            end = interval(.day, containing: d, calendar: calendar).end
        }
        return DateInterval(start: start, end: max(end, start))
    }

    /// Every hour interval from the hour containing `from` whose end is `<= to`, in order. A DST
    /// fall-back day yields 25 hours, a spring-forward day 23.
    public static func closedHours(from: Date, to: Date, calendar: Calendar) -> [DateInterval] {
        var hours: [DateInterval] = []
        var cursor = from
        while let hour = calendar.dateInterval(of: .hour, for: cursor), hour.end <= to, hour.end > cursor {
            hours.append(hour)
            cursor = hour.end
        }
        return hours
    }

    static func hourKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        let offset = calendar.timeZone.secondsFromGMT(for: date)
        let minutes = abs(offset) / 60
        return String(format: "%04d-%02d-%02dT%02d%@%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0,
                      offset < 0 ? "-" : "+", minutes / 60, minutes % 60)
    }
}
