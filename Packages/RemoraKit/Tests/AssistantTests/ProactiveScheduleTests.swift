import Foundation
import GRDB
import Testing
@testable import Assistant
import Storage

@Suite struct ReminderArmingTests {
    let now = local("2026-11-20 10:00")

    @Test func armsJustAfterTheNextFiring() {
        let d = ReminderArming.delay(nextFireAt: now.addingTimeInterval(90), now: now)
        #expect(d == 90 + ReminderArming.slack)
    }

    @Test func farOrNoFiringStillWakesEveryFiveMinutes() {
        #expect(ReminderArming.delay(nextFireAt: now.addingTimeInterval(86_400), now: now) == 300)
        #expect(ReminderArming.delay(nextFireAt: nil, now: now) == 300)
    }

    @Test func overdueFiresAtOnce() {
        #expect(ReminderArming.delay(nextFireAt: now.addingTimeInterval(-3_600), now: now) == 0)
    }
}

@Suite struct ChatRetentionTests {
    let now = local("2026-11-20 10:00")

    @Test func dueWhenNeverRunOrADayOld() {
        #expect(ChatRetention.isDue(lastPruneAt: nil, now: now))
        #expect(ChatRetention.isDue(lastPruneAt: now.addingTimeInterval(-86_400), now: now))
        #expect(!ChatRetention.isDue(lastPruneAt: now.addingTimeInterval(-3_600), now: now))
    }

    @Test func clockMovedBackCountsAsDue() {
        #expect(ChatRetention.isDue(lastPruneAt: now.addingTimeInterval(86_400 * 3), now: now))
    }

    @Test func prunesOlderThan90DaysOnceADay() throws {
        let db = try AppDatabase.inMemory()
        let store = ChatStore(db)
        _ = try store.append(ChatTurn(createdAt: now.addingTimeInterval(-91 * 86_400), role: .user, text: "old", status: .complete))
        _ = try store.append(ChatTurn(createdAt: now.addingTimeInterval(-89 * 86_400), role: .user, text: "kept", status: .complete))
        #expect(try ChatRetention.pruneIfDue(db: db, now: now) == 1)
        #expect(try store.turns(limit: 10).map(\.text) == ["kept"])
        #expect(try SettingsStore(db).value(Date.self, forKey: ChatRetention.lastPruneKey) == now)
        // Within the day: not run again.
        _ = try store.append(ChatTurn(createdAt: now.addingTimeInterval(-100 * 86_400), role: .user, text: "late", status: .complete))
        #expect(try ChatRetention.pruneIfDue(db: db, now: now.addingTimeInterval(3_600)) == nil)
        #expect(try store.turns(limit: 10).count == 2)
    }
}
