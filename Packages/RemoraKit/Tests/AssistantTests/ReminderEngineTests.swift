import Foundation
import Synchronization
import Testing
@testable import Assistant
import Storage

final class Clock: Sendable {
    private let t: Mutex<Date>
    private let zone: Mutex<String>
    init(_ s: String, zone: String = "Europe/Paris") { t = Mutex(at(s)); self.zone = Mutex(zone) }
    var now: Date { t.withLock { $0 } }
    func set(_ s: String) { t.withLock { $0 = at(s) } }
    func setZone(_ z: String) { zone.withLock { $0 = z } }
    var calendar: Calendar { makeCalendar(zone.withLock { $0 }) }
}

private func make(_ clock: Clock) throws -> (ReminderEngine, ReminderStore, AppDatabase) {
    let db = try AppDatabase.inMemory()
    let store = ReminderStore(db)
    let engine = ReminderEngine(store: store, db: db, calendar: { clock.calendar }, now: { clock.now })
    return (engine, store, db)
}

private func draft(_ schedule: ReminderSchedule, text: String = "Call Anna", action: ReminderAction = .notify) -> ReminderDraft {
    ReminderDraft(text: text, action: action, schedule: schedule, origin: .user)
}

@Suite struct ReminderEngineTests {
    @Test func createValidates() async throws {
        let clock = Clock("2026-11-20T10:00:00+01:00")
        let (e, _, _) = try make(clock)
        await #expect(throws: ReminderError.inPast) { try await e.create(draft(.once(at("2026-11-20T09:59:00+01:00")))) }
        await #expect(throws: ReminderError.tooFar) { try await e.create(draft(.once(at("2029-11-20T10:00:00+01:00")))) }
        await #expect(throws: ReminderError.intervalTooShort(minimumMinutes: 60)) {
            try await e.create(draft(.interval(seconds: 30 * 60, anchor: clock.now), action: .prompt))
        }
        await #expect(throws: ReminderError.intervalTooShort(minimumMinutes: 5)) {
            try await e.create(draft(.interval(seconds: 4 * 60, anchor: clock.now)))
        }
        await #expect(throws: ReminderError.emptyText) { try await e.create(draft(.once(at("2026-11-21T10:00:00+01:00")), text: "  \n")) }
        // 2 years is allowed; 50 active are allowed, the 51st is not.
        _ = try await e.create(draft(.once(at("2028-11-20T09:00:00+01:00"))))
        for i in 1..<50 { _ = try await e.create(draft(.once(at("2026-12-01T10:00:00+01:00")), text: "r\(i)")) }
        await #expect(throws: ReminderError.tooMany) { try await e.create(draft(.once(at("2026-12-02T10:00:00+01:00")))) }
    }

    @Test func createStoresTheZoneTheFirstFireAndStampsTheWallClock() async throws {
        let clock = Clock("2026-11-18T10:00:00+01:00")
        let (e, store, _) = try make(clock)
        let rule = try RecurrenceRule.parse("FREQ=WEEKLY;BYDAY=FR", calendar: paris)
        let r = try await e.create(draft(.recurring(rule, anchor: at("2026-11-18T17:00:00+01:00"))))
        #expect(r.timeZone == "Europe/Paris")
        #expect(r.kind == .recurring)
        #expect(r.nextFireAt == at("2026-11-20T17:00:00+01:00"))
        #expect(r.rrule == "FREQ=WEEKLY;BYDAY=FR;BYHOUR=17;BYMINUTE=0")
        #expect(try store.get(r.id!)?.nextFireAt == r.nextFireAt)
    }

    @Test func onceFiresThenDone() async throws {
        let clock = Clock("2026-11-20T10:00:00+01:00")
        let (e, store, _) = try make(clock)
        let r = try await e.create(draft(.once(at("2026-11-20T11:00:00+01:00"))))
        #expect(try await e.nextFireAt() == at("2026-11-20T11:00:00+01:00"))
        #expect(try await e.fireDue().isEmpty)
        clock.set("2026-11-20T11:00:30+01:00")
        let f = try await e.fireDue()
        #expect(f.count == 1)
        #expect(f[0].scheduledFor == at("2026-11-20T11:00:00+01:00"))
        #expect(f[0].late == false)
        let after = try #require(try store.get(r.id!))
        #expect(after.status == .done && after.nextFireAt == nil && after.fireCount == 1)
        #expect(after.lastFiredAt == clock.now)
        #expect(try await e.fireDue().isEmpty)
        #expect(try await e.nextFireAt() == nil)
    }

    @Test func lateIsMoreThanTwoMinutesBehind() async throws {
        let clock = Clock("2026-11-20T10:00:00+01:00")
        let (e, _, _) = try make(clock)
        _ = try await e.create(draft(.once(at("2026-11-20T11:00:00+01:00"))))
        clock.set("2026-11-20T11:02:00+01:00")
        #expect(try await e.fireDue().first?.late == false)
        _ = try await e.create(draft(.once(at("2026-11-20T12:00:00+01:00"))))
        clock.set("2026-11-20T12:02:01+01:00")
        #expect(try await e.fireDue().first?.late == true)
    }

    @Test func missedRecurringCollapsesToOneLateFiring() async throws {
        let clock = Clock("2026-11-16T07:00:00+01:00") // Monday
        let (e, store, _) = try make(clock)
        let rule = try RecurrenceRule.parse("FREQ=DAILY;BYHOUR=9;BYMINUTE=0", calendar: paris)
        let r = try await e.create(draft(.recurring(rule, anchor: clock.now)))
        #expect(r.nextFireAt == at("2026-11-16T09:00:00+01:00"))
        clock.set("2026-11-19T11:00:00+01:00") // asleep Mon 08:00 to Thu 11:00
        let f = try await e.fireDue()
        #expect(f.count == 1)
        #expect(f[0].scheduledFor == at("2026-11-19T09:00:00+01:00"))
        #expect(f[0].late)
        let after = try #require(try store.get(r.id!))
        #expect(after.nextFireAt == at("2026-11-20T09:00:00+01:00"))
        #expect(after.fireCount == 1 && after.status == .active)
    }

    @Test func intervalRealignsAfterSleep() async throws {
        let clock = Clock("2026-11-20T10:00:00+01:00")
        let (e, store, _) = try make(clock)
        let r = try await e.create(draft(.interval(seconds: 15 * 60, anchor: clock.now)))
        #expect(r.nextFireAt == at("2026-11-20T10:15:00+01:00"))
        clock.set("2026-11-20T11:07:00+01:00")
        let f = try await e.fireDue()
        #expect(f.count == 1)
        #expect(f[0].scheduledFor == at("2026-11-20T11:00:00+01:00"))
        #expect(f[0].late)
        #expect(try store.get(r.id!)?.nextFireAt == at("2026-11-20T11:15:00+01:00"))
    }

    @Test func countEndsRecurrence() async throws {
        let clock = Clock("2026-11-20T08:00:00+01:00")
        let (e, store, _) = try make(clock)
        let rule = try RecurrenceRule.parse("FREQ=DAILY;COUNT=2;BYHOUR=9;BYMINUTE=0", calendar: paris)
        let r = try await e.create(draft(.recurring(rule, anchor: clock.now)))
        clock.set("2026-11-20T09:00:00+01:00")
        #expect(try await e.fireDue().count == 1)
        #expect(try store.get(r.id!)?.status == .active)
        clock.set("2026-11-21T09:00:00+01:00")
        #expect(try await e.fireDue().count == 1)
        let after = try #require(try store.get(r.id!))
        #expect(after.status == .done && after.nextFireAt == nil && after.fireCount == 2)
        clock.set("2026-11-22T09:00:00+01:00")
        #expect(try await e.fireDue().isEmpty)
    }

    @Test func recurringKeepsWallClockAcrossTheSpringForwardDST() async throws {
        let clock = Clock("2026-03-28T08:00:00+01:00")
        let (e, store, _) = try make(clock)
        let rule = try RecurrenceRule.parse("FREQ=DAILY;BYHOUR=9;BYMINUTE=0", calendar: paris)
        let r = try await e.create(draft(.recurring(rule, anchor: clock.now)))
        clock.set("2026-03-28T09:00:00+01:00")
        #expect(try await e.fireDue().count == 1)
        #expect(try store.get(r.id!)?.nextFireAt == at("2026-03-29T09:00:00+02:00"))
        clock.set("2026-03-29T09:00:00+02:00")
        #expect(try await e.fireDue().count == 1)
        #expect(try store.get(r.id!)?.nextFireAt == at("2026-03-30T09:00:00+02:00"))
    }

    @Test func timeZoneChangeKeepsLocalTime() async throws {
        let clock = Clock("2026-11-18T08:00:00+01:00")
        let (e, store, _) = try make(clock)
        let rule = try RecurrenceRule.parse("FREQ=DAILY;BYHOUR=9;BYMINUTE=0", calendar: paris)
        let r = try await e.create(draft(.recurring(rule, anchor: clock.now)))
        #expect(r.nextFireAt == at("2026-11-18T09:00:00+01:00"))
        clock.set("2026-11-18T09:00:00+01:00")
        #expect(try await e.fireDue().count == 1)
        // The Mac flies to New York overnight: still 09:00 local, not 09:00 Paris.
        clock.setZone("America/New_York")
        clock.set("2026-11-19T01:00:00-05:00")
        #expect(try await e.nextFireAt() == at("2026-11-19T09:00:00-05:00"))
        let after = try #require(try store.get(r.id!))
        #expect(after.timeZone == "America/New_York")
        #expect(try await e.fireDue().isEmpty)
    }

    @Test func cancelAndReactivate() async throws {
        let clock = Clock("2026-11-20T10:00:00+01:00")
        let (e, store, _) = try make(clock)
        let r = try await e.create(draft(.once(at("2026-11-20T11:00:00+01:00"))))
        let c = try await e.cancel(r.id!)
        #expect(c.status == .cancelled)
        #expect(try await e.nextFireAt() == nil)
        #expect(try await e.list().isEmpty)
        clock.set("2026-11-20T12:00:00+01:00")
        #expect(try await e.fireDue().isEmpty)
        // A past one-off cannot come back; a still-future one can.
        await #expect(throws: ReminderError.inPast) { try await e.reactivate(r.id!) }
        let r2 = try await e.create(draft(.once(at("2026-11-20T15:00:00+01:00"))))
        _ = try await e.cancel(r2.id!)
        let back = try await e.reactivate(r2.id!)
        #expect(back.status == .active && back.nextFireAt == at("2026-11-20T15:00:00+01:00"))
        #expect(try store.get(r2.id!)?.status == .active)
        await #expect(throws: ReminderError.notFound) { try await e.cancel(9999) }
    }

    @Test func reactivateRecurringRecomputesTheNextOccurrence() async throws {
        let clock = Clock("2026-11-20T08:00:00+01:00")
        let (e, _, _) = try make(clock)
        let rule = try RecurrenceRule.parse("FREQ=DAILY;BYHOUR=9;BYMINUTE=0", calendar: paris)
        let r = try await e.create(draft(.recurring(rule, anchor: clock.now)))
        _ = try await e.cancel(r.id!)
        clock.set("2026-11-25T12:00:00+01:00")
        #expect(try await e.reactivate(r.id!).nextFireAt == at("2026-11-26T09:00:00+01:00"))
    }

    @Test func dueRemindersFireOldestFirst() async throws {
        let clock = Clock("2026-11-20T10:00:00+01:00")
        let (e, _, _) = try make(clock)
        _ = try await e.create(draft(.once(at("2026-11-20T12:00:00+01:00")), text: "b"))
        _ = try await e.create(draft(.once(at("2026-11-20T11:00:00+01:00")), text: "a"))
        clock.set("2026-11-20T13:00:00+01:00")
        #expect(try await e.fireDue().map(\.reminder.text) == ["a", "b"])
    }

    @Test func recurringFiringAcrossTheFallBackDay() async throws {
        let clock = Clock("2026-10-24T08:00:00+02:00")
        let (e, store, _) = try make(clock)
        let rule = try RecurrenceRule.parse("FREQ=DAILY;BYHOUR=9;BYMINUTE=0", calendar: paris)
        let r = try await e.create(draft(.recurring(rule, anchor: clock.now)))
        clock.set("2026-10-24T09:00:00+02:00")
        #expect(try await e.fireDue().count == 1)
        #expect(try store.get(r.id!)?.nextFireAt == at("2026-10-25T09:00:00+01:00"))
        // Asleep through the 25-hour day.
        clock.set("2026-10-26T11:00:00+01:00")
        let f = try await e.fireDue()
        #expect(f.count == 1 && f[0].scheduledFor == at("2026-10-26T09:00:00+01:00") && f[0].late)
        #expect(try store.get(r.id!)?.nextFireAt == at("2026-10-27T09:00:00+01:00"))
    }

    @Test func tooFarAppliesToRecurringAndIntervalFirstFire() async throws {
        let clock = Clock("2028-03-01T10:00:00+01:00")
        let (e, _, _) = try make(clock)
        let rule = try RecurrenceRule.parse("FREQ=MONTHLY;INTERVAL=12;BYMONTHDAY=29;BYHOUR=9;BYMINUTE=0", calendar: paris)
        await #expect(throws: ReminderError.tooFar) {
            try await e.create(draft(.recurring(rule, anchor: at("2028-02-29T09:00:00+01:00"))))
        }
        await #expect(throws: ReminderError.tooFar) {
            try await e.create(draft(.interval(seconds: 600, anchor: at("2031-01-01T00:00:00+01:00"))))
        }
    }

    @Test func cancelOnADoneReminderIsANoOp() async throws {
        let clock = Clock("2026-11-20T10:00:00+01:00")
        let (e, store, _) = try make(clock)
        let r = try await e.create(draft(.once(at("2026-11-20T11:00:00+01:00"))))
        clock.set("2026-11-20T11:00:00+01:00")
        _ = try await e.fireDue()
        #expect(try await e.cancel(r.id!).status == .done)
        #expect(try store.get(r.id!)?.status == .done)
    }

    @Test func fireDueNeverMarksAStillValidRuleDone() async throws {
        let clock = Clock("2026-11-20T10:00:00+01:00")
        let (e, store, _) = try make(clock)
        // A stored rule with no future match inside the horizon (never ended): stays active.
        let row = try store.insert(Reminder(text: "x", action: .notify, kind: .recurring, anchorAt: at("2026-02-10T09:00:00+01:00"),
                                            rrule: "FREQ=MONTHLY;INTERVAL=12;BYMONTHDAY=31;BYHOUR=9;BYMINUTE=0",
                                            timeZone: "Europe/Paris", nextFireAt: at("2026-11-20T09:00:00+01:00"),
                                            createdBy: .user, createdAt: clock.now))
        let f = try await e.fireDue()
        #expect(f.count == 1)
        #expect(try store.get(row.id!)?.status == .active)
    }

    @Test func createKeepsAUserGivenMinute() async throws {
        let clock = Clock("2026-11-18T10:00:00+01:00")
        let (e, _, _) = try make(clock)
        let rule = try RecurrenceRule.parse("FREQ=DAILY;BYMINUTE=30", calendar: paris)
        let r = try await e.create(draft(.recurring(rule, anchor: at("2026-11-18T17:05:00+01:00"))))
        #expect(r.rrule == "FREQ=DAILY;BYHOUR=17;BYMINUTE=30")
    }
}
