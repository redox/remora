import Foundation
import Testing
@testable import Memory

private func stat(_ h: Int, _ focus: TimeInterval, snaps: Int = 1, day: Int = 20) -> HourStat {
    HourStat(hour: DateInterval(start: date(2026, 11, day, h), end: date(2026, 11, day, h + 1)),
             focusSeconds: focus, snapshotCount: snaps)
}

@Test func sparseHoursMergeWithinDay() {
    let stats = [stat(9, 120), stat(10, 200), stat(11, 400), stat(12, 3000)]
    let spans = HourBatcher.plan(stats, newestClosedHourEnd: date(2026, 11, 20, 20), now: date(2026, 11, 20, 21), calendar: paris)
    #expect(spans.map(\.start) == [date(2026, 11, 20, 9), date(2026, 11, 20, 12)])
    #expect(spans.map(\.end) == [date(2026, 11, 20, 12), date(2026, 11, 20, 13)])
    #expect(spans.map(\.hours) == [3, 1])
    #expect(spans.map(\.key) == ["2026-11-20T09+0100", "2026-11-20T12+0100"])
}

@Test func spanStopsAtFourHours() {
    let stats = (8..<14).map { stat($0, 60) }  // 6 sparse hours, 360 s in total
    let spans = HourBatcher.plan(stats, newestClosedHourEnd: date(2026, 11, 20, 20), now: date(2026, 11, 20, 21), calendar: paris)
    #expect(spans.map(\.hours) == [4, 2])
}

@Test func hoursWithNothingAreDropped() {
    let stats = [stat(9, 59, snaps: 0), stat(10, 30, snaps: 0), stat(11, 60, snaps: 0), stat(12, 10, snaps: 2)]
    let spans = HourBatcher.plan(stats, newestClosedHourEnd: date(2026, 11, 20, 20), now: date(2026, 11, 20, 21), calendar: paris)
    // 09 and 10 have neither 60 s of focus nor a snapshot; 11 and 12 are adjacent sparse hours.
    #expect(spans.map(\.start) == [date(2026, 11, 20, 11)])
    #expect(spans.map(\.hours) == [2])
}

@Test func sparseSpanNeverCrossesMidnight() {
    let stats = [stat(22, 100), stat(23, 100), HourStat(hour: DateInterval(start: date(2026, 11, 21, 0), end: date(2026, 11, 21, 1)),
                                                         focusSeconds: 100, snapshotCount: 1)]
    let spans = HourBatcher.plan(stats, newestClosedHourEnd: date(2026, 11, 21, 10), now: date(2026, 11, 21, 12), calendar: paris)
    #expect(spans.map(\.start) == [date(2026, 11, 20, 22), date(2026, 11, 21, 0)])
    #expect(spans.map(\.hours) == [2, 1])
}

@Test func trailingSparseSpanWaits() {
    let stats = [stat(9, 3000), stat(10, 100)]
    let end = date(2026, 11, 20, 11)
    let early = HourBatcher.plan(stats, newestClosedHourEnd: end, now: end.addingTimeInterval(20 * 60), calendar: paris)
    #expect(early.map(\.start) == [date(2026, 11, 20, 9)])
    let late = HourBatcher.plan(stats, newestClosedHourEnd: end, now: end.addingTimeInterval(3 * 3_600), calendar: paris)
    #expect(late.map(\.start) == [date(2026, 11, 20, 9), date(2026, 11, 20, 10)])
}

@Test func trailingSparseSpanEndingAtMidnightDoesNotWait() {
    let stats = [stat(23, 100)]
    let end = date(2026, 11, 21, 0)
    let spans = HourBatcher.plan(stats, newestClosedHourEnd: end, now: end.addingTimeInterval(20 * 60), calendar: paris)
    #expect(spans.map(\.start) == [date(2026, 11, 20, 23)])
}

@Test func busyTrailingHourIsPlannedImmediately() {
    let end = date(2026, 11, 20, 11)
    let spans = HourBatcher.plan([stat(10, 2000)], newestClosedHourEnd: end, now: end.addingTimeInterval(600), calendar: paris)
    #expect(spans.count == 1)
}
