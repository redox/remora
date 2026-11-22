import Foundation
import Testing
@testable import Storage

private func paris() -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Europe/Paris")!
    return c
}

private func date(_ c: Calendar, _ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
    c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

@Test func untilTomorrowAfterEight() {
    let c = paris()
    #expect(PauseDuration.untilTomorrow.end(from: date(c, 2026, 5, 5, 14, 30), calendar: c) == date(c, 2026, 5, 6, 8))
}

@Test func untilTomorrowBeforeEightIsStillNextDay() {
    let c = paris()
    #expect(PauseDuration.untilTomorrow.end(from: date(c, 2026, 5, 5, 3), calendar: c) == date(c, 2026, 5, 6, 8))
}

@Test func untilTomorrowMonthAndYearBoundaries() {
    let c = paris()
    #expect(PauseDuration.untilTomorrow.end(from: date(c, 2026, 1, 31, 22), calendar: c) == date(c, 2026, 2, 1, 8))
    #expect(PauseDuration.untilTomorrow.end(from: date(c, 2026, 12, 31, 23, 59), calendar: c) == date(c, 2027, 1, 1, 8))
}

@Test func untilTomorrowAcrossDST() {
    let c = paris()
    // Spring forward 2026-03-29, fall back 2026-10-25: always 08:00 local wall time.
    for (now, expected) in [(date(c, 2026, 3, 28, 22), date(c, 2026, 3, 29, 8)),
                            (date(c, 2026, 3, 29, 10), date(c, 2026, 3, 30, 8)),
                            (date(c, 2026, 10, 24, 23), date(c, 2026, 10, 25, 8)),
                            (date(c, 2026, 10, 25, 10), date(c, 2026, 10, 26, 8))] {
        let end = PauseDuration.untilTomorrow.end(from: now, calendar: c)
        #expect(end == expected)
        #expect(c.dateComponents([.hour, .minute], from: end) == DateComponents(hour: 8, minute: 0))
    }
}

@Test func fixedDurations() {
    let now = Date(timeIntervalSince1970: 1_000)
    #expect(PauseDuration.minutes15.end(from: now) == now + 900)
    #expect(PauseDuration.hour1.end(from: now) == now + 3600)
}

@Test func indefinitelyRoundTripsThroughSettings() throws {
    let s = SettingsStore(try .inMemory())
    try s.pause(until: PauseDuration.indefinitely.end(from: .now))
    #expect(try s.pausedUntil() == .distantFuture)
    #expect(try s.isPaused(now: .now))
}
