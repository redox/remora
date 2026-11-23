import ChatBar
import Foundation
import Storage
import Testing
@testable import Assistant

/// Every number and settings name the guide states, tied to the constant that ships (Plan 5
/// Task 12 carry). A changed constant fails here until the guide's copy is updated.
@Suite struct FeatureGuideFiguresTests {
    private func body(_ id: String) throws -> String {
        // Continuation lines of a bullet keep their indent: compare with single spaces.
        try #require(FeatureGuide.sections.first { $0.id == id }).body
            .replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
    }

    private func hhmm(_ hour: Int) -> String { String(format: "%02d:00", hour) }

    private var calendar: Calendar {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = TimeZone(identifier: "Europe/Paris")!
        return c
    }

    @Test func reminderFiguresMatchTheEngine() throws {
        let r = try body("reminders")
        #expect(r.contains("at least \(ReminderEngine.minNotifyIntervalMinutes) minutes"))
        #expect(r.contains("at least \(ReminderEngine.minPromptIntervalMinutes) minutes apart"))
        #expect(r.contains("Up to \(ReminderEngine.maxActive) active reminders"))
        #expect(ReminderEngine.maxAheadYears == 2 && r.contains("up to two years ahead"))
    }

    /// Binding ruling: reminders always notify (subject to macOS permission), even with proactive
    /// messages off; only briefs and nudges follow the switch. The guide must say so.
    @Test func notificationCopyMatchesTheNotifierPolicy() throws {
        let r = try body("reminders"), b = try body("briefs-and-nudges"), t = try body("troubleshooting")
        #expect(ProactiveNotifications.wantsNotification(.reminder, proactiveEnabled: false))
        #expect(r.contains("even while proactive messages are off") && r.contains("they always notify"))
        #expect(!r.contains("only while proactive messages are on"))
        for kind in [InboxKind.morningBrief, .eveningWrap, .nudge] {
            #expect(!ProactiveNotifications.wantsNotification(kind, proactiveEnabled: false))
        }
        #expect(b.contains("Turning proactive messages off stops briefs and nudges only; reminders still arrive in the chat and still notify."))
        #expect(!b.contains("without a notification."))
        #expect(t.contains("proactive messages on, for briefs and nudges"))
        // Briefs: the notification is held while sharing; the chat still gets the brief.
        #expect(ProactiveNotifications.heldWhileSharing(.morningBrief) && ProactiveNotifications.heldWhileSharing(.eveningWrap))
        #expect(!ProactiveNotifications.heldWhileSharing(.reminder))
        #expect(b.contains("a brief that lands while you are sharing your screen stays in the chat, without a notification"))
    }

    @Test func forgetCopyNamesTheChatAndChatHistory() throws {
        let p = try body("pause-and-delete")
        #expect(!p.contains("Memory page"))
        #expect(p.contains("**Forget** specific captures by asking the chat"))
        #expect(p.contains("Forgetting a capture also stops Remora from reusing earlier chat messages in new answers; Clear chat removes them from view."))
        #expect(p.contains("clears Remora's notifications"))
    }

    @Test func briefTimesMatchTheBriefWindows() throws {
        let b = try body("briefs-and-nudges")
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        let morning = BriefKind.morning.window(day: day, calendar: calendar)
        let evening = BriefKind.evening.window(day: day, calendar: calendar)
        #expect(b.contains("**Morning brief** at \(hhmm(calendar.component(.hour, from: morning.start)))"))
        #expect(calendar.component(.hour, from: morning.end) == 12 && b.contains("until noon"))
        #expect(b.contains("**Evening wrap** at \(hhmm(calendar.component(.hour, from: evening.start)))"))
        #expect(evening.end == calendar.dateInterval(of: .day, for: day)!.end && b.contains("until midnight"))
    }

    @Test func nudgeLimitsMatchThePlanner() throws {
        let b = try body("briefs-and-nudges")
        #expect(b.contains("At most \(ProactivePlanner.dailyNudgeCap) a day"))
        #expect(b.contains("at least \(Int(ProactivePlanner.nudgeGap / 60)) minutes apart"))
        #expect(b.contains("between \(hhmm(ProactivePlanner.nudgeHours.lowerBound)) and \(hhmm(ProactivePlanner.nudgeHours.upperBound))"))
        let days = Int(BriefEvidence.recentActivity / 86_400)
        #expect(try body("troubleshooting").contains("no capture in the last \(days) days"))
    }

    @Test func historyAndRetentionMatchStorage() throws {
        #expect(try body("chat-bar").contains("(\(ChatRetention.days) days)"))
        #expect(!(try body("usage").contains("budget")))
        guard case .days(let d) = MemorySettings.defaultRetention else { Issue.record("retention"); return }
        #expect(try body("memory").contains("\(d) days by default"))
    }

    @Test func textSizeRangeMatchesBarSettings() throws {
        var s = BarSettings()
        s.textScale = 0
        let low = Int((s.textScale * 100).rounded())
        s.textScale = 9
        let high = Int((s.textScale * 100).rounded())
        #expect(try body("chat-bar").contains("text size \(low)–\(high) %"))
    }

    @Test func pauseUntilTomorrowHourMatches() throws {
        let end = PauseDuration.untilTomorrow.end(from: Date(timeIntervalSince1970: 1_790_000_000), calendar: calendar)
        #expect(try body("pause-and-delete").contains("until tomorrow (\(hhmm(calendar.component(.hour, from: end))))"))
    }

    /// The Settings sidebar's pinned order (Task 12); the app's `SettingsTab` uses the same names.
    @Test func settingsPagesMatchTheSidebar() throws {
        let pages = ["General", "Account", "Usage", "Privacy", "Appearance", "Identity", "Memory", "Notifications",
                     "Shortcuts", "Dictation", "Meeting sources", "MCP", "Logs"]
        let listed = try body("settings").split(separator: "\n")
            .compactMap { line -> String? in
                guard line.hasPrefix("- **"), let end = line.range(of: ":**") else { return nil }
                return String(line[line.index(line.startIndex, offsetBy: 4)..<end.lowerBound])
            }
        #expect(listed == pages)
        #expect(try body("briefs-and-nudges").contains("Settings › Notifications"))
        #expect(try body("settings").contains("Show onboarding again"))
    }
}
