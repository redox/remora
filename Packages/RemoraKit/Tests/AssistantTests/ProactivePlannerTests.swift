import Foundation
import GRDB
import Memory
import Testing
@testable import Assistant
import Storage

private func signals(_ now: Date, memory: Bool = true) -> SchedulerSignals {
    SchedulerSignals(now: now, idleSeconds: 10, onPower: true, lowPower: false, accountReady: true,
                     onDeviceAvailable: true, memoryEnabled: memory)
}

private func planned(_ db: AppDatabase, _ now: Date, enabled: Bool = true, memory: Bool = true) throws -> [JobSpec] {
    try ProactivePlanner(db: db, calendar: paris, enabled: { enabled }).plan(signals(now, memory: memory)).specs
}

private func nudge(_ db: AppDatabase, at: Date, key: String) throws {
    try db.writer.write { d in
        var m = InboxMessage(kind: .nudge, title: "Nudge", body: "b", dedupeKey: key, createdAt: at)
        try m.insert(d)
    }
}

@Suite struct ProactivePlannerTests {
    @Test func routineScanStartsAfterSevenDaysOfHistory() throws {
        let db = try AppDatabase.inMemory()
        let first = local("2026-11-13 10:00")
        try ActivityStore(db).recordFocus(app: "Notes", bundleID: nil, windowTitle: "Weekly notes", domain: nil, at: first)
        let before = try planned(db, local("2026-11-20 09:59"))
        #expect(before.allSatisfy { $0.kind != .routineScan })
        let eligible = try planned(db, local("2026-11-20 10:00"))
        let routine = try #require(eligible.first { $0.kind == .routineScan })
        #expect(routine.periodKey == "2026-W47")
        #expect(routine.periodEnd == local("2026-11-23 00:00"))
        #expect(try planned(db, local("2026-11-20 11:00"), enabled: false).isEmpty)
        #expect(try planned(db, local("2026-11-20 11:00"), memory: false).isEmpty)

        let jobs = JobStore(db)
        try jobs.enqueue([routine], now: local("2026-11-20 10:00"))
        let row = try #require(try jobs.job(kind: .routineScan, periodKey: routine.periodKey))
        try jobs.complete(id: try #require(row.id), status: .done, now: local("2026-11-20 10:00"))
        #expect(try planned(db, local("2026-11-21 23:00")).allSatisfy { $0.kind != .routineScan })
        #expect(try planned(db, local("2026-11-23 23:00")).first { $0.kind == .routineScan }?.periodKey == "2026-W48")
    }

    @Test func morningCatchUpUntilNoonOnly() throws {
        let db = try AppDatabase.inMemory()
        let specs = try planned(db, local("2026-11-20 10:30"))
        let brief = try #require(specs.first { $0.kind == .morningBrief })
        #expect(brief.periodKey == "2026-11-20")
        #expect(brief.notBefore == local("2026-11-20 08:00"))
        #expect(brief.periodStart == local("2026-11-20 08:00"))
        #expect(brief.periodEnd == local("2026-11-20 12:00"))
        #expect(try planned(db, local("2026-11-20 12:30")).allSatisfy { $0.kind != .morningBrief })
        #expect(try planned(db, local("2026-11-20 07:59")).allSatisfy { $0.kind != .morningBrief })
    }

    @Test func eveningPlannedUntilMidnight() throws {
        let db = try AppDatabase.inMemory()
        let wrap = try #require(try planned(db, local("2026-11-20 23:50")).first { $0.kind == .eveningWrap })
        #expect(wrap.periodKey == "2026-11-20")
        #expect(wrap.notBefore == local("2026-11-20 16:00"))
        #expect(try planned(db, local("2026-11-20 15:59")).allSatisfy { $0.kind != .eveningWrap })
        // Past midnight the wrap of the previous day is never planned (nor today's, before 16:00).
        #expect(try planned(db, local("2026-11-21 00:05")).isEmpty)
    }

    @Test func disabledPlansNothing() throws {
        let db = try AppDatabase.inMemory()
        for t in ["2026-11-20 08:30", "2026-11-20 10:00", "2026-11-20 17:00"] {
            #expect(try !planned(db, local(t)).isEmpty)
            #expect(try planned(db, local(t), enabled: false).isEmpty)
            // Background memory off: no evidence, so no proactive job either.
            #expect(try planned(db, local(t), memory: false).isEmpty)
        }
        // The proactive planner never moves the memory planner's watermark.
        let plan = try ProactivePlanner(db: db, calendar: paris, enabled: { true }).plan(signals(local("2026-11-20 10:00")))
        #expect(plan.watermark == nil)
        #expect(plan.requeues.isEmpty)
    }

    @Test func nudgeScanPlannedOnlyInWindowAndUnderCap() throws {
        let db = try AppDatabase.inMemory()
        #expect(try planned(db, local("2026-11-20 08:45")).allSatisfy { $0.kind != .nudgeScan })
        #expect(try planned(db, local("2026-11-20 19:00")).allSatisfy { $0.kind != .nudgeScan })
        let scan = try #require(try planned(db, local("2026-11-20 10:00")).first { $0.kind == .nudgeScan })
        #expect(scan.periodKey == "2026-11-20T10:00")
        #expect(scan.notBefore == local("2026-11-20 10:00"))
        #expect(scan.periodEnd == local("2026-11-20 10:30"))
        #expect(try planned(db, local("2026-11-20 18:59")).first { $0.kind == .nudgeScan }?.periodKey == "2026-11-20T18:30")

        // Last nudge 60 min ago: not planned; 2 h ago (2 today): planned.
        try nudge(db, at: local("2026-11-20 11:00"), key: "n1")
        #expect(try planned(db, local("2026-11-20 12:00")).allSatisfy { $0.kind != .nudgeScan })
        #expect(try planned(db, local("2026-11-20 13:00")).contains { $0.kind == .nudgeScan })
        // A nudge yesterday counts neither toward today's cap nor the gap.
        try nudge(db, at: local("2026-11-19 18:00"), key: "y")
        try nudge(db, at: local("2026-11-20 09:00"), key: "n0")
        #expect(try planned(db, local("2026-11-20 13:00")).contains { $0.kind == .nudgeScan })
        // 3 nudges today: never again today.
        try nudge(db, at: local("2026-11-20 14:00"), key: "n2")
        #expect(try planned(db, local("2026-11-20 17:00")).allSatisfy { $0.kind != .nudgeScan })
    }

    @Test func skippedBriefIsRequeuedWhileItsWindowLasts() throws {
        func skipped(_ reason: String, at: Date, kind: JobKind = .morningBrief) throws -> AppDatabase {
            let db = try AppDatabase.inMemory()
            let store = JobStore(db)
            try store.enqueue([JobSpec(kind: kind, periodKey: "2026-11-20", notBefore: at)], now: at)
            let job = try #require(try store.job(kind: kind, periodKey: "2026-11-20"))
            try store.complete(id: job.id!, status: .skipped, reason: reason, now: at)
            return db
        }
        func requeues(_ db: AppDatabase, _ now: Date) throws -> [JobRef] {
            try ProactivePlanner(db: db, calendar: paris, enabled: { true }).plan(signals(now)).requeues
        }
        let want = JobRef(kind: .morningBrief, periodKey: "2026-11-20", ifStatusIn: [.skipped])
        for reason in ["no activity", "cloud_denied", "evidence changed"] {
            let db = try skipped(reason, at: local("2026-11-20 08:00"))
            #expect(try requeues(db, local("2026-11-20 08:20")).isEmpty)       // skipped < 30 min ago
            #expect(try requeues(db, local("2026-11-20 08:31")) == [want])
        }
        for reason in ["unverified", "duplicate", "disabled", "window passed"] {
            #expect(try requeues(try skipped(reason, at: local("2026-11-20 08:00")), local("2026-11-20 09:00")).isEmpty)
        }
        // Less than 15 min of the window left: never.
        let late = try skipped("no activity", at: local("2026-11-20 11:00"))
        #expect(try requeues(late, local("2026-11-20 11:50")).isEmpty)
        #expect(try requeues(late, local("2026-11-20 11:40")) == [want])
        // Already delivered today (by another path): never.
        let sent = try skipped("no activity", at: local("2026-11-20 08:00"))
        try sent.writer.write { d in
            var m = InboxMessage(kind: .morningBrief, title: "Morning brief", body: "b", dedupeKey: "morning_brief:2026-11-20",
                                 createdAt: local("2026-11-20 08:05"))
            try m.insert(d)
        }
        #expect(try requeues(sent, local("2026-11-20 09:00")).isEmpty)
        // The evening wrap the same way; off or memory off: nothing.
        let evening = try skipped("no activity", at: local("2026-11-20 16:00"), kind: .eveningWrap)
        #expect(try requeues(evening, local("2026-11-20 17:00"))
                == [JobRef(kind: .eveningWrap, periodKey: "2026-11-20", ifStatusIn: [.skipped])])
        #expect(try ProactivePlanner(db: evening, calendar: paris, enabled: { false })
                .plan(signals(local("2026-11-20 17:00"))).requeues.isEmpty)
    }

    @Test func briefsDoNotCountTowardTheNudgeCap() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { d in
            for (kind, key, t) in [(InboxKind.morningBrief, "morning_brief:2026-11-20", "2026-11-20 08:30"),
                                   (.reminder, "reminder:1:1", "2026-11-20 09:00"), (.reminder, "reminder:1:2", "2026-11-20 09:20"),
                                   (.reminder, "reminder:1:3", "2026-11-20 09:40")] {
                var m = InboxMessage(kind: kind, title: "t", body: "b", dedupeKey: key, createdAt: local(t))
                try m.insert(d)
            }
        }
        #expect(try planned(db, local("2026-11-20 10:00")).contains { $0.kind == .nudgeScan })
        let nudge = try await makeInbox(db).deliver(
            kind: .nudge, title: "Nudge", body: "b", dedupeKey: "nudge:1", callIDs: [], expectedGeneration: 0,
            nudgeCap: (cap: 3, minGap: 5_400, dayStart: local("2026-11-20 00:00")), at: local("2026-11-20 10:00"))
        #expect(nudge != nil)
    }
}
