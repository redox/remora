import Foundation
import GRDB
import Testing
@testable import Storage

@Test func dueRemindersOrdered() throws {
    let db = try AppDatabase.inMemory()
    let store = ReminderStore(db)
    let now = assistantT0
    let late = try store.insert(.fixture(text: "late", nextFireAt: now.addingTimeInterval(-60)))
    let early = try store.insert(.fixture(text: "early", nextFireAt: now.addingTimeInterval(-3_600)))
    let exact = try store.insert(.fixture(text: "exact", nextFireAt: now))
    _ = try store.insert(.fixture(text: "future", nextFireAt: now.addingTimeInterval(60)))
    _ = try store.insert(.fixture(text: "done", nextFireAt: now.addingTimeInterval(-7_200), status: .done))
    let cancelled = try store.insert(.fixture(text: "cancelled", nextFireAt: now.addingTimeInterval(-7_200)))
    try store.setStatus(cancelled.id!, .cancelled)

    #expect(try store.due(at: now).map(\.id) == [early.id, late.id, exact.id])
    #expect(try db.reader.read { try store.due(at: now, in: $0) }.map(\.text) == ["early", "late", "exact"])
    #expect(try store.due(at: now.addingTimeInterval(-86_400)).isEmpty)
}

@Test func activeRemindersSortByNextFireAndNextFireAtIsTheEarliestActive() throws {
    let db = try AppDatabase.inMemory()
    let store = ReminderStore(db)
    let now = assistantT0
    _ = try store.insert(.fixture(text: "b", nextFireAt: now.addingTimeInterval(7_200)))
    _ = try store.insert(.fixture(text: "a", nextFireAt: now.addingTimeInterval(3_600)))
    _ = try store.insert(.fixture(text: "unscheduled", nextFireAt: nil))
    _ = try store.insert(.fixture(text: "old", nextFireAt: now.addingTimeInterval(-60), status: .done))
    #expect(try store.active().map(\.text) == ["a", "b", "unscheduled"])
    #expect(try store.nextFireAt() == now.addingTimeInterval(3_600))
    try db.writer.write { d in _ = try Reminder.deleteAll(d) }
    #expect(try store.nextFireAt() == nil)
}

@Test func reminderUpdateGetAndStatus() throws {
    let db = try AppDatabase.inMemory()
    let store = ReminderStore(db)
    var r = try store.insert(.fixture(text: "water"))
    #expect(r.id != nil)
    #expect(try store.get(r.id!) == r)
    r.fireCount = 1
    r.lastFiredAt = assistantT0
    r.nextFireAt = assistantT0.addingTimeInterval(3_600)
    try db.writer.write { try store.update(r, in: $0) }
    #expect(try store.get(r.id!) == r)
    try store.setStatus(r.id!, .done)
    #expect(try store.get(r.id!)?.status == .done)
    #expect(try store.active().isEmpty)
    #expect(try store.get(9_999) == nil)
}
