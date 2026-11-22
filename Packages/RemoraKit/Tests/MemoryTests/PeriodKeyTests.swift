import Foundation
import Storage
import Testing
@testable import Memory

@Test func keysPerLevel() {
    let d = date(2026, 11, 20, 14, 37)
    #expect(PeriodKey.key(.hour, for: d, calendar: paris) == "2026-11-20T14+0100")
    #expect(PeriodKey.key(.day, for: d, calendar: paris) == "2026-11-20")
    #expect(PeriodKey.key(.week, for: d, calendar: paris) == "2026-W47")
    #expect(PeriodKey.key(.month, for: d, calendar: paris) == "2026-11")
    #expect(PeriodKey.key(.year, for: d, calendar: paris) == "2026")
    #expect(PeriodKey.workingMemorySlot(d, calendar: paris) == "2026-11-20T14+0100:30")
    #expect(PeriodKey.workingMemorySlot(date(2026, 11, 20, 14, 9), calendar: paris) == "2026-11-20T14+0100:00")
    #expect(PeriodKey.wikiSlot(d, calendar: paris) == "2026-11-20T12+0100")
    #expect(PeriodKey.wikiSlot(date(2026, 11, 20, 2, 59), calendar: paris) == "2026-11-20T00+0100")
    // Summer offset.
    #expect(PeriodKey.key(.hour, for: date(2026, 7, 1, 9), calendar: paris) == "2026-07-01T09+0200")
}

@Test func intervalsContainTheDate() {
    let d = date(2026, 11, 20, 14, 37)
    #expect(PeriodKey.interval(.hour, containing: d, calendar: paris) == DateInterval(start: date(2026, 11, 20, 14), end: date(2026, 11, 20, 15)))
    #expect(PeriodKey.interval(.day, containing: d, calendar: paris) == DateInterval(start: date(2026, 11, 20), end: date(2026, 11, 21)))
    #expect(PeriodKey.interval(.week, containing: d, calendar: paris) == DateInterval(start: date(2026, 11, 16), end: date(2026, 11, 23)))
    #expect(PeriodKey.interval(.month, containing: d, calendar: paris) == DateInterval(start: date(2026, 11, 1), end: date(2026, 12, 1)))
    #expect(PeriodKey.interval(.year, containing: d, calendar: paris) == DateInterval(start: date(2026, 1, 1), end: date(2027, 1, 1)))
}

/// 2026-10-25: clocks go back at 03:00 +0200 → 02:00 +0100, so 02:30 happens twice.
@Test func fallBackHourGetsDistinctKeys() {
    let first = Date(timeIntervalSince1970: date(2026, 10, 25, 0).timeIntervalSince1970 + 2.5 * 3_600)  // 02:30 +0200
    let second = first.addingTimeInterval(3_600)                                                          // 02:30 +0100
    #expect(PeriodKey.key(.hour, for: first, calendar: paris) == "2026-10-25T02+0200")
    #expect(PeriodKey.key(.hour, for: second, calendar: paris) == "2026-10-25T02+0100")
    let day = PeriodKey.interval(.day, containing: first, calendar: paris)
    let hours = PeriodKey.closedHours(from: day.start, to: day.end, calendar: paris)
    #expect(hours.count == 25)
    #expect(Set(hours.map { PeriodKey.key(.hour, for: $0.start, calendar: paris) }).count == 25)
    #expect(hours.first?.start == day.start && hours.last?.end == day.end)
}

@Test func springForwardDayHas23Hours() {
    let day = PeriodKey.interval(.day, containing: date(2026, 3, 29, 12), calendar: paris)
    let hours = PeriodKey.closedHours(from: day.start, to: day.end, calendar: paris)
    #expect(hours.count == 23)
    #expect(Set(hours.map { PeriodKey.key(.hour, for: $0.start, calendar: paris) }).count == 23)
}

@Test func isoWeekStartsMonday() {
    #expect(PeriodKey.key(.week, for: date(2027, 1, 1, 12), calendar: paris) == "2026-W53")
    #expect(PeriodKey.key(.week, for: date(2026, 12, 28, 0, 1), calendar: paris) == "2026-W53")
    #expect(PeriodKey.key(.week, for: date(2027, 1, 4, 12), calendar: paris) == "2027-W01")
    #expect(PeriodKey.interval(.week, containing: date(2027, 1, 1, 12), calendar: paris).start == date(2026, 12, 28))
}

@Test func closedHoursOnlyIncludesFullyClosedHours() {
    let hours = PeriodKey.closedHours(from: date(2026, 11, 20, 9, 30), to: date(2026, 11, 20, 12, 30), calendar: paris)
    // 09:30 floors to the 09 hour; the 12 hour is still open at 12:30.
    #expect(hours.map(\.start) == [date(2026, 11, 20, 9), date(2026, 11, 20, 10), date(2026, 11, 20, 11)])
}

/// Slot boundaries come from local hour components, so on a DST day each slot contains its dates and
/// the slots tile the day.
@Test(arguments: [date(2026, 10, 25), date(2026, 3, 29), date(2026, 11, 20)])
func wikiSlotsTileDstDays(day: Date) {
    let dayInterval = PeriodKey.interval(.day, containing: day, calendar: paris)
    var slots: [DateInterval] = []
    for hour in PeriodKey.closedHours(from: dayInterval.start, to: dayInterval.end, calendar: paris) {
        let probe = hour.start.addingTimeInterval(1_800)
        let slot = PeriodKey.wikiSlotInterval(probe, calendar: paris)
        #expect(slot.contains(probe))
        #expect(PeriodKey.wikiSlot(probe, calendar: paris) == PeriodKey.key(.hour, for: slot.start, calendar: paris))
        if slots.last != slot { slots.append(slot) }
    }
    #expect(slots.count == 8)
    #expect(slots.first?.start == dayInterval.start && slots.last?.end == dayInterval.end)
    for (a, b) in zip(slots, slots.dropFirst()) { #expect(a.end == b.start) }
}

/// Final review #10: one auto-updating calendar and one level mapping, both in Storage.
@Test func productionCalendarFollowsTimeZoneChangesAndLevelsMapOnce() {
    #expect(PeriodKey.localCalendar.timeZone == TimeZone.autoupdatingCurrent)
    #expect(PeriodKey.localCalendar == MemoryCalendar.local)
    #expect(PeriodKey.localCalendar.identifier == .iso8601)
    #expect(ChronicleLevel.allCases.map(\.jobKind) == [.hour, .dayRollup, .weekRollup, .monthRollup, .yearRollup])
    for level in ChronicleLevel.allCases {
        #expect(PeriodKey.interval(level, containing: t0, calendar: paris)
                == paris.dateInterval(of: level.calendarComponent, for: t0), "\(level)")
    }
    #expect(ChronicleLevel.week.calendarComponent == .weekOfYear)
}
