import Foundation
import GRDB
import LLM
import Storage
import Testing
@testable import Assistant

@Suite struct RoutineTests {
    @Test func repeatedTransitionsHaveDatedEvidence() async throws {
        let fixture = try Fixture()
        try fixture.seedRoutine()
        let run = await fixture.findRoutines()
        #expect(!run.output.contains("Metric history"))
        #expect(!run.output.contains("Published updates"))
        let result = try #require(try Fixture.decode(run).first)
        #expect(result["observed_days"] as? Int == 3)
        #expect(result["observed_focus_seconds"] as? Int == 90)
        let observations = try #require(result["observations"] as? [[String: Any]])
        #expect(observations.compactMap { $0["date"] as? String } == ["2026-11-20", "2026-11-13", "2026-11-06"])
        #expect(observations.allSatisfy { $0["first_time"] as? String == "10:00" })
        let steps = try #require(result["steps"] as? [[String: Any]])
        #expect(steps.compactMap { $0["title"] as? String } == ["Weekly metrics", "Team updates"])
    }

    @Test func unchangedWindowsStillCountAsNewVisits() async throws {
        let fixture = try Fixture()
        try fixture.seedTransition(day: -15)
        for day in [-8, -1] { try fixture.seedTransition(day: day, capture: false) }
        #expect(try await fixture.suggestions().first?["observed_days"] as? Int == 3)
    }

    @Test func differentNamedWindowsInTheSameAppCanFormARoutine() async throws {
        let fixture = try Fixture()
        for day in [-15, -8, -1] { try fixture.seedTransition(day: day, secondApp: "Dashboard") }
        #expect(try await fixture.suggestions().count == 1)
    }

    @Test func aRoutineCanEmergeWithinOneWeek() async throws {
        let fixture = try Fixture()
        for day in [-5, -3, -1] { try fixture.seedTransition(day: day) }
        #expect(try await fixture.suggestions().count == 1)
    }

    @Test func aLocationRuleHidesOlderVisitsWithoutAVerifiableLocation() async throws {
        let fixture = try Fixture()
        try fixture.seedTransition(day: -15)
        for day in [-8, -1] { try fixture.seedTransition(day: day, capture: false) }
        try ExclusionStore(fixture.db).add("path:private")
        #expect(try await fixture.suggestions().isEmpty)
    }

    @Test func aSavedHostAloneCannotVerifyAURLRule() async throws {
        let fixture = try Fixture()
        try fixture.seedRoutine()
        try await fixture.db.writer.write { d in
            try d.execute(sql: "UPDATE snapshots SET domain = 'example.com' WHERE app = 'Dashboard'")
            try d.execute(sql: "UPDATE activity_events SET domain = 'example.com' WHERE app = 'Dashboard'")
        }
        try ExclusionStore(fixture.db).add("url:/private/")
        #expect(try await fixture.suggestions().isEmpty)
    }

    @Test func missingDocumentPathCannotVerifyAPathRule() async throws {
        let fixture = try Fixture()
        try fixture.seedRoutine(withPaths: false)
        try ExclusionStore(fixture.db).add("path:private")
        #expect(try await fixture.suggestions().isEmpty)
    }

    @Test func verifiedCaptureDoesNotExposeTheEarlierPartOfAMixedLocationVisit() async throws {
        let fixture = try Fixture()
        let activity = ActivityStore(fixture.db)
        let snapshots = SnapshotStore(fixture.db)
        let today = fixture.calendar.startOfDay(for: fixture.now)
        for day in [-15, -8, -1] {
            let start = try #require(fixture.calendar.date(byAdding: .day, value: day, to: today))
                .addingTimeInterval(10 * 3600)
            // The title and host stayed the same when a private page became a public page.
            for offset in stride(from: 0.0, through: 80.0, by: 20.0) {
                try activity.recordFocus(app: "Dashboard", bundleID: nil, windowTitle: "Weekly metrics",
                                         domain: "example.com", at: start.addingTimeInterval(offset))
            }
            _ = try snapshots.insert(Snapshot(capturedAt: start.addingTimeInterval(60), app: "Dashboard",
                windowTitle: "Weekly metrics", url: "https://example.com/public/report", domain: "example.com",
                text: "Public sample", contentHash: UUID().uuidString, source: .ax))
            try fixture.visit(app: "Messages", title: "Team updates", text: "Published updates",
                              at: start.addingTimeInterval(600), capture: true)
        }
        try ExclusionStore(fixture.db).add("url:/private/")
        let result = try #require(try await fixture.suggestions().first)
        #expect(result["observed_focus_seconds"] == nil)
        let observations = try #require(result["observations"] as? [[String: Any]])
        #expect(observations.allSatisfy { $0["first_time"] as? String == "10:01" && $0["focus_seconds"] == nil })
    }

    @Test func repeatsOnOneDayDoNotCountAsARoutine() async throws {
        let fixture = try Fixture()
        for offset in [0, 2, 4] { try fixture.seedTransition(day: -1, hour: 10 + offset) }
        #expect(try await fixture.suggestions().isEmpty)
    }

    @Test func widelySeparatedWindowsDoNotCountAsTransitions() async throws {
        let fixture = try Fixture()
        for day in [-15, -8, -1] { try fixture.seedTransition(day: day, gap: 55 * 60) }
        #expect(try await fixture.suggestions().isEmpty)
    }

    @Test func aNewTitleExclusionHidesTheOldEvidence() async throws {
        let fixture = try Fixture()
        try fixture.seedRoutine()
        try ExclusionStore(fixture.db).add("title:Weekly metrics")
        #expect(try await fixture.suggestions().isEmpty)
    }

    @Test func correctionIsVisibleInTheNextConversation() async throws {
        let fixture = try Fixture()
        try fixture.seedRoutine()
        let id = try #require(try await fixture.suggestions().first?["id"] as? String)
        let arguments = #"{"id":"\#(id)","operation":"rename","label":"Friday status update"}"#
        let declined = try await fixture.update(arguments, confirm: { _ in false })
        #expect(declined.confirmed == false)
        #expect(try await fixture.suggestions().first?["label"] == nil)
        let accepted = try await fixture.update(arguments, confirm: { _ in true })
        #expect(accepted.confirmed == true)
        #expect(try await fixture.suggestions().first?["label"] as? String == "Friday status update")
    }

    @Test func dismissalSurvivesAnotherScan() async throws {
        let fixture = try Fixture()
        try fixture.seedRoutine()
        let id = try #require(try await fixture.suggestions().first?["id"] as? String)
        let update = try await fixture.update(#"{"id":"\#(id)","operation":"dismiss","label":""}"#, confirm: { _ in true })
        #expect(update.confirmed == true)
        #expect(try await fixture.suggestions().isEmpty)
    }

    @Test func forgettingAnObservationRemovesAnUnsupportedRoutine() async throws {
        let fixture = try Fixture()
        try fixture.seedRoutine()
        #expect(try await fixture.suggestions().count == 1)
        let recent = try #require(fixture.calendar.date(byAdding: .day, value: -1, to: fixture.calendar.startOfDay(for: fixture.now)))
        let ids = try SnapshotStore(fixture.db).recent(limit: 20).filter { $0.capturedAt >= recent }.map(\.id)
        _ = try SnapshotStore(fixture.db).delete(ids: ids, now: fixture.now)
        #expect(try await fixture.suggestions().isEmpty)
    }

    @Test func exclusionAddedDuringConfirmationRefusesTheWrite() async throws {
        let fixture = try Fixture()
        try fixture.seedRoutine()
        let id = try #require(try await fixture.suggestions().first?["id"] as? String)
        let run = try await fixture.update(#"{"id":"\#(id)","operation":"dismiss","label":""}"#, confirm: { _ in
            do { try ExclusionStore(fixture.db).add("title:Weekly metrics") }
            catch { Issue.record("Could not add the exclusion") }
            return true
        })
        #expect(run.isError)
        try ExclusionStore(fixture.db).remove("title:Weekly metrics")
        #expect(try await fixture.suggestions().count == 1)
    }

    @Test func aCaptureThatRollsDuringConfirmationNoLongerSupportsTheAction() async throws {
        let fixture = try Fixture()
        try fixture.seedRoutine()
        try ExclusionStore(fixture.db).add("path:private")
        let id = try #require(try await fixture.suggestions().first?["id"] as? String)
        let sample = try #require(try SnapshotStore(fixture.db).recent(limit: 1).first)
        let run = try await fixture.update(#"{"id":"\#(id)","operation":"dismiss","label":""}"#, confirm: { _ in
            do {
                try fixture.db.writer.write { d in
                    try d.execute(sql: "UPDATE snapshots SET captured_at = ? WHERE id = ?",
                                  arguments: [sample.capturedAt.addingTimeInterval(5), sample.id])
                }
            } catch { Issue.record("Could not roll the sample") }
            return true
        })
        #expect(run.isError)
        #expect(try SettingsStore(fixture.db).value([String: RoutineFeedback].self, forKey: RoutineFeedback.settingsKey) == nil)
    }

    private struct Fixture: Sendable {
        let db: AppDatabase
        let calendar = makeCalendar("UTC")
        let now = Date(timeIntervalSince1970: 1_795_262_400)  // 21 November 2026 at 12:00 UTC.

        init() throws { db = try AppDatabase.inMemory() }

        func seedRoutine(withPaths: Bool = true) throws {
            for day in [-15, -8, -1] { try seedTransition(day: day, withPaths: withPaths) }
        }

        func seedTransition(day: Int, hour: Int = 10, gap: TimeInterval = 600, capture: Bool = true,
                            secondApp: String = "Messages", withPaths: Bool = true) throws {
            let date = try #require(calendar.date(byAdding: .day, value: day, to: calendar.startOfDay(for: now)))
            let start = date.addingTimeInterval(Double(hour * 3600))
            try visit(app: "Dashboard", title: "Weekly metrics", text: "Metric history", at: start,
                      capture: capture, filePath: withPaths ? "/Users/me/metrics.txt" : nil)
            try visit(app: secondApp, title: "Team updates", text: "Published updates",
                      at: start.addingTimeInterval(gap), capture: capture, filePath: withPaths ? "/Users/me/updates.txt" : nil)
        }

        func visit(app: String, title: String, text: String, at: Date, capture: Bool, filePath: String? = nil) throws {
            let activity = ActivityStore(db)
            for offset in [0.0, 15.0] {
                try activity.recordFocus(app: app, bundleID: nil, windowTitle: title, domain: nil,
                                         at: at.addingTimeInterval(offset))
            }
            if capture {
                _ = try SnapshotStore(db).insert(Snapshot(capturedAt: at, app: app, windowTitle: title, filePath: filePath,
                    text: text, contentHash: UUID().uuidString, source: .ax))
            }
        }

        func suggestions() async throws -> [[String: Any]] {
            try Self.decode(await findRoutines())
        }

        func findRoutines() async -> ToolRun {
            let tool = RoutineSuggestionsTool(db: db)
            #expect(tool.kind == .untrustedRead)
            return await tool.run(arguments: "{}", context: context(confirm: { _ in false }))
        }

        static func decode(_ run: ToolRun) throws -> [[String: Any]] {
            #expect(!run.isError)
            let object = try #require(try JSONSerialization.jsonObject(with: Data(run.output.utf8)) as? [String: Any])
            return try #require(object["routines"] as? [[String: Any]])
        }

        func update(_ arguments: String, confirm: @escaping @Sendable (ActionProposal) async -> Bool) async throws -> ToolRun {
            let reminders = ReminderEngine(store: ReminderStore(db), db: db, calendar: { calendar })
            let tools = ActionTools.all(reminders: reminders, db: db, effects: RoutineTestEffects(), now: { now })
            let tool = try #require(tools.first { $0.definition.name == "update_routine" })
            return await tool.run(arguments: arguments, context: context(confirm: confirm))
        }

        func context(confirm: @escaping @Sendable (ActionProposal) async -> Bool) -> ToolContext {
            ToolContext(now: now, calendar: calendar, turnTainted: false, confirm: confirm)
        }
    }
}

private struct RoutineTestEffects: ActionEffects {
    func didChange(_ change: ActionChange) async {}
}
