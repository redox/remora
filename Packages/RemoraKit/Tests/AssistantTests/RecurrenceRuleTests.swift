import Foundation
import Testing
@testable import Assistant
import Storage

func makeCalendar(_ zone: String = "Europe/Paris") -> Calendar {
    var c = Calendar(identifier: .iso8601)
    c.timeZone = TimeZone(identifier: zone)!
    return c
}
let paris = makeCalendar()

/// An instant written with an explicit offset, so DST expectations are unambiguous.
func at(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

@Suite struct RecurrenceRuleTests {
    @Test(arguments: ["FREQ=WEEKLY;BYDAY=FR;BYHOUR=17;BYMINUTE=0", "RRULE:FREQ=DAILY;INTERVAL=2", "FREQ=MONTHLY;BYMONTHDAY=-1",
                      "FREQ=WEEKLY;BYDAY=MO,TH;COUNT=4", "FREQ=DAILY;UNTIL=20261231T235959Z"])
    func parsesAndRoundTrips(_ s: String) throws {
        let r = try RecurrenceRule.parse(s, calendar: paris)
        #expect(try RecurrenceRule.parse(r.rrule, calendar: paris) == r)
        #expect(!r.rrule.hasPrefix("RRULE:"))
    }

    @Test func untilAcceptsLocalDateAndDateTime() throws {
        let d = try RecurrenceRule.parse("FREQ=DAILY;UNTIL=20261231", calendar: paris)
        #expect(d.until == at("2026-12-31T23:59:59+01:00"))
        let t = try RecurrenceRule.parse("FREQ=DAILY;UNTIL=20261231T101500", calendar: paris)
        #expect(t.until == at("2026-12-31T10:15:00+01:00"))
    }

    @Test(arguments: [("FREQ=YEARLY", RecurrenceError.unsupported("FREQ=YEARLY")),
                      ("FREQ=WEEKLY;BYDAY=1MO", .unsupported("BYDAY=1MO")),
                      ("FREQ=DAILY;INTERVAL=0", .invalid("INTERVAL=0")),
                      ("FREQ=DAILY;BYSETPOS=1", .unsupported("BYSETPOS=1")),
                      ("FREQ=MONTHLY;BYMONTHDAY=0", .invalid("BYMONTHDAY=0")),
                      ("FREQ=DAILY;BYHOUR=24", .invalid("BYHOUR=24")),
                      ("FREQ=DAILY;COUNT=0", .invalid("COUNT=0")),
                      ("FREQ=DAILY;COUNT=2;UNTIL=20270101", .invalid("COUNT=2;UNTIL")),
                      ("FREQ=DAILY;INTERVAL=366", .invalid("INTERVAL=366")),
                      ("FREQ=WEEKLY;INTERVAL=53", .invalid("INTERVAL=53")),
                      ("FREQ=MONTHLY;INTERVAL=13", .invalid("INTERVAL=13")),
                      ("INTERVAL=2", .invalid("FREQ")),
                      ("FREQ=WEEKLY;BYDAY=XX", .invalid("BYDAY=XX"))])
    func rejects(_ s: String, _ e: RecurrenceError) {
        #expect(throws: e) { try RecurrenceRule.parse(s, calendar: paris) }
    }

    @Test func everyFridayAt17() throws {
        let r = try RecurrenceRule.parse("FREQ=WEEKLY;BYDAY=FR;BYHOUR=17;BYMINUTE=0", calendar: paris)
        let anchor = at("2026-11-18T10:00:00+01:00")
        #expect(r.next(after: anchor, anchor: anchor, calendar: paris) == at("2026-11-20T17:00:00+01:00"))
        #expect(r.next(after: at("2026-11-20T17:00:00+01:00"), anchor: anchor, calendar: paris) == at("2026-11-27T17:00:00+01:00"))
    }

    @Test func everyOtherWeekSkipsTheOffWeek() throws {
        let r = try RecurrenceRule.parse("FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH;BYHOUR=9;BYMINUTE=30", calendar: paris)
        let anchor = at("2026-11-16T09:30:00+01:00") // a Monday
        #expect(r.next(after: anchor, anchor: anchor, calendar: paris) == at("2026-11-19T09:30:00+01:00"))
        // The next Monday (11-23) and Thursday (11-26) are in the off week.
        #expect(r.next(after: at("2026-11-19T09:30:00+01:00"), anchor: anchor, calendar: paris) == at("2026-11-30T09:30:00+01:00"))
    }

    @Test func lastDayOfMonth() throws {
        let r = try RecurrenceRule.parse("FREQ=MONTHLY;BYMONTHDAY=-1;BYHOUR=8;BYMINUTE=0", calendar: paris)
        let anchor = at("2027-01-31T08:00:00+01:00")
        #expect(r.next(after: at("2027-02-10T12:00:00+01:00"), anchor: anchor, calendar: paris) == at("2027-02-28T08:00:00+01:00"))
        #expect(r.next(after: at("2027-02-28T08:00:00+01:00"), anchor: anchor, calendar: paris) == at("2027-03-31T08:00:00+02:00"))
    }

    @Test func lastDayOfFebruaryInALeapYear() throws {
        let r = try RecurrenceRule.parse("FREQ=MONTHLY;BYMONTHDAY=-1;BYHOUR=8;BYMINUTE=0", calendar: paris)
        let anchor = at("2028-01-31T08:00:00+01:00")
        #expect(r.next(after: at("2028-02-10T12:00:00+01:00"), anchor: anchor, calendar: paris) == at("2028-02-29T08:00:00+01:00"))
    }

    @Test func day31SkipsShortMonths() throws {
        let r = try RecurrenceRule.parse("FREQ=MONTHLY;BYMONTHDAY=31;BYHOUR=9;BYMINUTE=0", calendar: paris)
        let anchor = at("2026-10-31T09:00:00+01:00")
        #expect(r.next(after: at("2026-11-01T00:00:00+01:00"), anchor: anchor, calendar: paris) == at("2026-12-31T09:00:00+01:00"))
    }

    @Test func day29SkipsFebruaryInACommonYear() throws {
        let r = try RecurrenceRule.parse("FREQ=MONTHLY;BYMONTHDAY=29;BYHOUR=9;BYMINUTE=0", calendar: paris)
        let anchor = at("2027-01-29T09:00:00+01:00")
        #expect(r.next(after: at("2027-01-30T00:00:00+01:00"), anchor: anchor, calendar: paris) == at("2027-03-29T09:00:00+02:00"))
    }

    @Test func leapDayEveryTwelveMonthsWaitsForTheNextLeapYear() throws {
        let r = try RecurrenceRule.parse("FREQ=MONTHLY;INTERVAL=12;BYMONTHDAY=29;BYHOUR=9;BYMINUTE=0", calendar: paris)
        let anchor = at("2028-02-29T09:00:00+01:00")
        #expect(r.next(after: anchor, anchor: anchor, calendar: paris) == at("2032-02-29T09:00:00+01:00"))
    }

    @Test func dstKeepsWallClockTimeSpringForward() throws {
        let r = try RecurrenceRule.parse("FREQ=DAILY;BYHOUR=9;BYMINUTE=0", calendar: paris)
        let anchor = at("2026-03-20T09:00:00+01:00")
        // 2026-03-29: Paris jumps from 02:00 to 03:00.
        #expect(r.next(after: at("2026-03-28T09:00:00+01:00"), anchor: anchor, calendar: paris) == at("2026-03-29T09:00:00+02:00"))
        #expect(r.next(after: at("2026-03-29T09:00:00+02:00"), anchor: anchor, calendar: paris) == at("2026-03-30T09:00:00+02:00"))
    }

    @Test func dstKeepsWallClockTimeFallBack() throws {
        let r = try RecurrenceRule.parse("FREQ=DAILY;BYHOUR=9;BYMINUTE=0", calendar: paris)
        let anchor = at("2026-10-20T09:00:00+02:00")
        // 2026-10-25: Paris goes back from 03:00 to 02:00, a 25-hour day.
        #expect(r.next(after: at("2026-10-24T09:00:00+02:00"), anchor: anchor, calendar: paris) == at("2026-10-25T09:00:00+01:00"))
        #expect(r.next(after: at("2026-10-25T09:00:00+01:00"), anchor: anchor, calendar: paris) == at("2026-10-26T09:00:00+01:00"))
    }

    @Test func nonexistentTimeMovesForward() throws {
        let r = try RecurrenceRule.parse("FREQ=DAILY;BYHOUR=2;BYMINUTE=30", calendar: paris)
        let anchor = at("2026-03-27T02:30:00+01:00")
        #expect(r.next(after: at("2026-03-28T02:30:00+01:00"), anchor: anchor, calendar: paris) == at("2026-03-29T03:30:00+02:00"))
        // And the next day is back on 02:30.
        #expect(r.next(after: at("2026-03-29T03:30:00+02:00"), anchor: anchor, calendar: paris) == at("2026-03-30T02:30:00+02:00"))
    }

    @Test func repeatedTimeFiresOnceOnTheFallBackDay() throws {
        let r = try RecurrenceRule.parse("FREQ=DAILY;BYHOUR=2;BYMINUTE=30", calendar: paris)
        let anchor = at("2026-10-23T02:30:00+02:00")
        let first = r.next(after: at("2026-10-24T02:30:00+02:00"), anchor: anchor, calendar: paris)
        #expect(first == at("2026-10-25T02:30:00+02:00"))
        // After the first 02:30 the repeated 02:30 (+01:00) is NOT a second occurrence.
        #expect(r.next(after: first!, anchor: anchor, calendar: paris) == at("2026-10-26T02:30:00+01:00"))
    }

    @Test func timeOfDayDefaultsToTheAnchorsLocalTime() throws {
        let r = try RecurrenceRule.parse("FREQ=DAILY", calendar: paris)
        let anchor = at("2026-11-18T14:45:00+01:00")
        #expect(r.next(after: anchor, anchor: anchor, calendar: paris) == at("2026-11-19T14:45:00+01:00"))
    }

    @Test func timeZoneChangeKeepsLocalTime() throws {
        // Created in Paris for 09:00 (the engine stamps BYHOUR from the anchor); evaluated in New York.
        let r = try RecurrenceRule.parse("FREQ=DAILY;BYHOUR=9;BYMINUTE=0", calendar: paris)
        let ny = makeCalendar("America/New_York")
        let anchor = at("2026-11-18T09:00:00+01:00")
        let now = at("2026-11-19T20:00:00-05:00")
        #expect(r.next(after: now, anchor: anchor, calendar: ny) == at("2026-11-20T09:00:00-05:00"))
    }

    @Test func countStopsAfterThatManyOccurrences() throws {
        let r = try RecurrenceRule.parse("FREQ=DAILY;COUNT=3;BYHOUR=9;BYMINUTE=0", calendar: paris)
        let anchor = at("2026-11-18T09:00:00+01:00")
        #expect(r.next(after: at("2026-11-19T09:00:00+01:00"), anchor: anchor, calendar: paris) == at("2026-11-20T09:00:00+01:00"))
        #expect(r.next(after: at("2026-11-20T09:00:00+01:00"), anchor: anchor, calendar: paris) == nil)
    }

    @Test func untilStopsTheRecurrence() throws {
        let r = try RecurrenceRule.parse("FREQ=DAILY;UNTIL=20261120;BYHOUR=9;BYMINUTE=0", calendar: paris)
        let anchor = at("2026-11-18T09:00:00+01:00")
        #expect(r.next(after: at("2026-11-19T09:00:00+01:00"), anchor: anchor, calendar: paris) == at("2026-11-20T09:00:00+01:00"))
        #expect(r.next(after: at("2026-11-20T09:00:00+01:00"), anchor: anchor, calendar: paris) == nil)
    }

    @Test func neverReturnsAnOccurrenceBeforeTheAnchor() throws {
        let r = try RecurrenceRule.parse("FREQ=DAILY;BYHOUR=9;BYMINUTE=0", calendar: paris)
        let anchor = at("2026-11-18T10:00:00+01:00")
        #expect(r.next(after: at("2026-11-01T00:00:00+01:00"), anchor: anchor, calendar: paris) == at("2026-11-19T09:00:00+01:00"))
    }

    @Test func neverMatchingRuleTerminatesWithNil() throws {
        // Day 31 every 12 months from February: no December/January/... 31st ever lines up.
        let r = try RecurrenceRule.parse("FREQ=MONTHLY;INTERVAL=12;BYMONTHDAY=31;BYHOUR=9;BYMINUTE=0", calendar: paris)
        let anchor = at("2026-02-10T09:00:00+01:00")
        #expect(r.next(after: anchor, anchor: anchor, calendar: paris) == nil)
        #expect(r.nextOccurrence(after: anchor, anchor: anchor, calendar: paris) == .exhausted)
    }

    @Test func largestAllowedIntervalsAreStillFound() throws {
        let anchor = at("2026-01-01T09:00:00+01:00")
        let d = try RecurrenceRule.parse("FREQ=DAILY;INTERVAL=365;BYHOUR=9;BYMINUTE=0", calendar: paris)
        #expect(d.next(after: anchor, anchor: anchor, calendar: paris) == at("2027-01-01T09:00:00+01:00"))
        let w = try RecurrenceRule.parse("FREQ=WEEKLY;INTERVAL=52;BYHOUR=9;BYMINUTE=0", calendar: paris)
        #expect(w.next(after: anchor, anchor: anchor, calendar: paris) == at("2026-12-31T09:00:00+01:00"))
        let m = try RecurrenceRule.parse("FREQ=MONTHLY;INTERVAL=12;BYHOUR=9;BYMINUTE=0", calendar: paris)
        #expect(m.next(after: anchor, anchor: anchor, calendar: paris) == at("2027-01-01T09:00:00+01:00"))
    }

    @Test func monthlyIntervalSkipsTheOffMonths() throws {
        let r = try RecurrenceRule.parse("FREQ=MONTHLY;INTERVAL=3;BYHOUR=9;BYMINUTE=0", calendar: paris)
        let anchor = at("2026-01-15T09:00:00+01:00")
        #expect(r.next(after: at("2026-01-16T00:00:00+01:00"), anchor: anchor, calendar: paris) == at("2026-04-15T09:00:00+02:00"))
        #expect(r.next(after: at("2026-04-15T09:00:00+02:00"), anchor: anchor, calendar: paris) == at("2026-07-15T09:00:00+02:00"))
        #expect(r.next(after: at("2026-07-15T09:00:00+02:00"), anchor: anchor, calendar: paris) == at("2026-10-15T09:00:00+02:00"))
    }

    @Test func countRuleFarFromTheAnchorKeepsWorking() throws {
        let r = try RecurrenceRule.parse("FREQ=DAILY;COUNT=10000;BYHOUR=9;BYMINUTE=0", calendar: paris)
        let anchor = at("2026-01-01T09:00:00+01:00")
        // ~5 years past the anchor, still within the 10000 occurrences.
        #expect(r.next(after: at("2031-06-10T09:00:00+02:00"), anchor: anchor, calendar: paris) == at("2031-06-11T09:00:00+02:00"))
        // Past the 10000th occurrence (2053-05-18) the rule has ended.
        #expect(r.nextOccurrence(after: at("2060-01-01T00:00:00+01:00"), anchor: anchor, calendar: paris) == .ended)
    }

    @Test func describeIsReadable() throws {
        let en = Locale(identifier: "en_US_POSIX")
        #expect(try RecurrenceRule.parse("FREQ=WEEKLY;BYDAY=FR;BYHOUR=17;BYMINUTE=0", calendar: paris).describe(calendar: paris, locale: en) == "Every Friday at 17:00")
        #expect(try RecurrenceRule.parse("FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH;BYHOUR=9;BYMINUTE=30", calendar: paris).describe(calendar: paris, locale: en) == "Every 2 weeks on Monday, Thursday at 09:30")
        #expect(try RecurrenceRule.parse("FREQ=MONTHLY;BYMONTHDAY=-1;BYHOUR=8;BYMINUTE=0", calendar: paris).describe(calendar: paris, locale: en) == "Every month on the last day at 08:00")
        #expect(try RecurrenceRule.parse("FREQ=DAILY;BYHOUR=9;BYMINUTE=0", calendar: paris).describe(calendar: paris, locale: en) == "Every day at 09:00")
        #expect(try RecurrenceRule.parse("FREQ=MONTHLY;BYMONTHDAY=15;BYHOUR=9;BYMINUTE=0", calendar: paris).describe(calendar: paris, locale: en) == "Every month on day 15 at 09:00")
    }

    @Test func describeInFrench() throws {
        let fr = Locale(identifier: "fr_FR")
        #expect(try RecurrenceRule.parse("FREQ=WEEKLY;BYDAY=FR;BYHOUR=17;BYMINUTE=0", calendar: paris).describe(calendar: paris, locale: fr) == "Chaque vendredi à 17:00")
        #expect(try RecurrenceRule.parse("FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH;BYHOUR=9;BYMINUTE=30", calendar: paris).describe(calendar: paris, locale: fr) == "Toutes les 2 semaines le lundi, jeudi à 09:30")
        #expect(try RecurrenceRule.parse("FREQ=MONTHLY;BYMONTHDAY=-1;BYHOUR=8;BYMINUTE=0", calendar: paris).describe(calendar: paris, locale: fr) == "Chaque mois le dernier jour à 08:00")
        #expect(try RecurrenceRule.parse("FREQ=DAILY;INTERVAL=3;BYHOUR=9;BYMINUTE=0", calendar: paris).describe(calendar: paris, locale: fr) == "Tous les 3 jours à 09:00")
    }
}
