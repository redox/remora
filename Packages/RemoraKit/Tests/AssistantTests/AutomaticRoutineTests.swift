import ChatBar
import Foundation
import Memory
import Storage
import Testing
@testable import Assistant

@Suite struct AutomaticRoutineTests {
    private let today = local("2026-11-21 11:00")

    @Test func aSchedulerTickFindsRoutinesWithoutAnAccountOrModelCall() async throws {
        let db = try AppDatabase.inMemory()
        try seedHistory(db)
        let inbox = makeInbox(db)
        let scheduler = MemoryScheduler(db: db, runners: [.routineScan: RoutineScanRunner(db: db, inbox: inbox)],
                                        planner: ProactivePlanner(db: db, calendar: paris, enabled: { true }),
                                        calendar: paris, now: { today })
        let report = await scheduler.tick(SchedulerSignals(now: today, idleSeconds: 150, onPower: false, lowPower: false,
                                                           accountReady: false, onDeviceAvailable: false, memoryEnabled: true))
        #expect(report.ran == [.routineScan])
        let message = try #require(try inboxRows(db).first)
        #expect(message.isRoutineFinding)
        #expect(message.body.contains("Weekly metrics"))
        #expect(message.body.contains("2026-11-20"))
        #expect(try jobTypes(db).isEmpty)
        let replay = try await db.reader.read { try ChatStore(db).replayable(in: $0).turns }
        #expect(replay.isEmpty)
    }

    @Test func seenRoutinesDoNotReturnNextWeekEvenIfChatIsCleared() async throws {
        let db = try AppDatabase.inMemory()
        try seedHistory(db)
        let runner = RoutineScanRunner(db: db, inbox: makeInbox(db))
        _ = try await run(runner, at: today)
        try ChatStore(db).clear()
        try seedVisitPair(db, at: local("2026-11-24 10:00"))
        _ = try await run(runner, at: local("2026-11-28 11:00"))
        #expect(try inboxRows(db).isEmpty)
    }

    @Test func turningOffProactiveMessagesSkipsACurrentlyQueuedScan() async throws {
        let db = try AppDatabase.inMemory()
        try seedHistory(db)
        try ProactiveSettings.setEnabled(false, SettingsStore(db))
        _ = try await run(RoutineScanRunner(db: db, inbox: makeInbox(db)), at: today)
        #expect(try inboxRows(db).isEmpty)
    }

    @Test func dismissedOrExcludedRoutinesAreNotSurfaced() async throws {
        let db = try AppDatabase.inMemory()
        try seedHistory(db)
        let found = try await db.reader.read { try RoutineSuggestions.find(db: db, now: today, calendar: paris, in: $0) }
        let candidate = try #require(found.candidates.first)
        try SettingsStore(db).setValue([candidate.id: RoutineFeedback.dismissed], forKey: RoutineFeedback.settingsKey)
        let runner = RoutineScanRunner(db: db, inbox: makeInbox(db))
        _ = try await run(runner, at: today)
        #expect(try inboxRows(db).isEmpty)
        try SettingsStore(db).setValue([String: RoutineFeedback]?.none, forKey: RoutineFeedback.settingsKey)
        try ExclusionStore(db).add("title:Weekly metrics")
        _ = try await run(runner, at: today)
        #expect(try inboxRows(db).isEmpty)
    }

    @Test func forgettingRemovesAutomaticFindingsFromTheInboxAndChat() async throws {
        let db = try AppDatabase.inMemory()
        try seedHistory(db)
        _ = try await run(RoutineScanRunner(db: db, inbox: makeInbox(db)), at: today)
        #expect(try inboxRows(db).count == 1)
        try await db.writer.write { try ForgetMarks.mark(now: today, in: $0) }
        #expect(try inboxRows(db).isEmpty)
        #expect(try chatRows(db).isEmpty)
        #expect(try SettingsStore(db).value([String: Date].self, forKey: RoutineFindings.seenKey) == nil)
    }

    @Test func aNewExclusionClearsExistingAutomaticFindings() async throws {
        let db = try AppDatabase.inMemory()
        try seedHistory(db)
        _ = try await run(RoutineScanRunner(db: db, inbox: makeInbox(db)), at: today)
        #expect(try inboxRows(db).count == 1)
        try ExclusionStore(db).add("title:Weekly metrics")
        #expect(try inboxRows(db).isEmpty)
        #expect(try chatRows(db).isEmpty)
    }

    @Test func aCapturedTitleCannotTurnIntoAnInboxLink() async throws {
        let db = try AppDatabase.inMemory()
        try seedHistory(db, title: "[Open](https://example.com)")
        _ = try await run(RoutineScanRunner(db: db, inbox: makeInbox(db)), at: today)
        let message = try #require(try inboxRows(db).first)
        #expect(MarkdownBlocks.linkHosts(MarkdownBlocks.inline(message.body)).isEmpty)
    }

    private func run(_ runner: RoutineScanRunner, at now: Date) async throws -> JobOutcome {
        let key = PeriodKey.key(.week, for: now, calendar: paris)
        return try await runner.run(Job(kind: .routineScan, periodKey: key, nextRunAt: now, createdAt: now),
                                    context: jobContext(now, cloud: false))
    }

    private func seedHistory(_ db: AppDatabase, title: String = "Weekly metrics") throws {
        for day in ["2026-11-07 10:00", "2026-11-14 10:00", "2026-11-20 10:00"] {
            try seedVisitPair(db, at: local(day), title: title)
        }
    }

    private func seedVisitPair(_ db: AppDatabase, at: Date, title: String = "Weekly metrics") throws {
        let activity = ActivityStore(db)
        for (app, title, offset) in [("Dashboard", title, 0.0), ("Messages", "Team updates", 60.0)] {
            for t in [offset, offset + 15] {
                try activity.recordFocus(app: app, bundleID: nil, windowTitle: title, domain: nil, at: at.addingTimeInterval(t))
            }
        }
    }
}
