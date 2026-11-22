import Foundation
import GRDB
import Synchronization
import Testing
@testable import Assistant
import Storage

/// Records what would have been posted; never touches `UNUserNotificationCenter`.
final class FakePoster: NotificationPosting {
    let auth: Mutex<NotificationAuth>
    let previews: Mutex<Bool>
    let grant: Bool
    let posted = Mutex<[ProactiveNotification]>([])
    let requests = Mutex(0)

    init(_ auth: NotificationAuth, previews: Bool = true, grant: Bool = true) {
        self.auth = Mutex(auth); self.previews = Mutex(previews); self.grant = grant
    }

    func status() async -> NotificationAuth { auth.withLock { $0 } }
    func previewsShown() async -> Bool { previews.withLock { $0 } }
    func request() async -> Bool {
        requests.withLock { $0 += 1 }
        auth.withLock { $0 = grant ? .authorized : .denied }
        return grant
    }
    func post(_ n: ProactiveNotification) async { posted.withLock { $0.append(n) } }
    func removeAllDelivered() async { posted.withLock { $0.removeAll() }; removals.withLock { $0 += 1 } }
    let removals = Mutex(0)
    var all: [ProactiveNotification] { posted.withLock { $0 } }
}

private func stored(_ db: AppDatabase, kind: InboxKind = .nudge, body: String = "Reply to Marc about the deck",
                    key: String = "k1", notified: Bool = false) throws -> InboxMessage {
    try db.writer.write { d in
        try InboxStore.insertIfNew(InboxMessage(kind: kind, title: "Nudge", body: body, dedupeKey: key,
                                                createdAt: local("2026-11-20 10:00"), notified: notified), in: d)!
    }
}

private func notifiedFlag(_ db: AppDatabase, _ id: Int64) throws -> Bool {
    try db.reader.read { d in try Bool.fetchOne(d, sql: "SELECT notified FROM inbox_messages WHERE id = ?", arguments: [id]) ?? false }
}

@Suite struct ProactiveNotifierTests {
    @Test func automaticRoutineFindingsStayInTheInboxWithoutAskingForNotificationPermission() async throws {
        let db = try AppDatabase.inMemory()
        let message = try stored(db, key: RoutineFindings.inboxKeyPrefix + "2026-W47")
        let poster = FakePoster(.notDetermined)
        #expect(await !ProactiveNotifier(db: db, poster: poster, enabled: { true }).notify(message))
        #expect(poster.all.isEmpty)
        #expect(poster.requests.withLock { $0 } == 0)
    }

    @Test func postsWhenEnabledAndAuthorizedThenMarksNotified() async throws {
        let db = try AppDatabase.inMemory()
        let m = try stored(db, kind: .morningBrief)
        let poster = FakePoster(.authorized)
        let posted = await ProactiveNotifier(db: db, poster: poster, enabled: { true }).notify(m)
        #expect(posted)
        #expect(poster.all == [ProactiveNotification(id: "inbox-\(m.id!)", title: "Nudge", body: "Reply to Marc about the deck",
                                                     thread: "morning_brief", inboxID: m.id)])
        #expect(try notifiedFlag(db, m.id!))
    }

    @Test func deniedPostsNothingAndNeverAsks() async throws {
        let db = try AppDatabase.inMemory()
        let m = try stored(db)
        let poster = FakePoster(.denied)
        #expect(await !ProactiveNotifier(db: db, poster: poster, enabled: { true }).notify(m))
        #expect(poster.all.isEmpty)
        #expect(poster.requests.withLock { $0 } == 0)
        #expect(try !notifiedFlag(db, m.id!))
    }

    /// The prompt comes with the first message about to notify, not at launch.
    @Test func firstDeliveryAsksOnceThenPosts() async throws {
        let db = try AppDatabase.inMemory()
        let poster = FakePoster(.notDetermined)
        let notifier = ProactiveNotifier(db: db, poster: poster, enabled: { true })
        #expect(await notifier.notify(try stored(db, key: "a")))
        #expect(await notifier.notify(try stored(db, key: "b")))
        #expect(poster.requests.withLock { $0 } == 1)
        #expect(poster.all.count == 2)
        #expect(try SettingsStore(db).value(Bool.self, forKey: ProactiveNotifications.askedKey) == true)
    }

    @Test func declinedFirstPromptIsNotRepeated() async throws {
        let db = try AppDatabase.inMemory()
        let poster = FakePoster(.notDetermined, grant: false)
        let notifier = ProactiveNotifier(db: db, poster: poster, enabled: { true })
        #expect(await !notifier.notify(try stored(db, key: "a")))
        #expect(await !notifier.notify(try stored(db, key: "b")))
        #expect(poster.requests.withLock { $0 } == 1)
        #expect(poster.all.isEmpty)
    }

    @Test func alreadyAskedNotDeterminedPostsNothingWithoutPrompt() async throws {
        let db = try AppDatabase.inMemory()
        try SettingsStore(db).setValue(true, forKey: ProactiveNotifications.askedKey)
        let poster = FakePoster(.notDetermined)
        #expect(await !ProactiveNotifier(db: db, poster: poster, enabled: { true }).notify(try stored(db)))
        #expect(poster.requests.withLock { $0 } == 0)
        #expect(poster.all.isEmpty)
    }

    @Test(arguments: [InboxKind.morningBrief, .eveningWrap, .nudge])
    func proactiveOffPostsNoBriefOrNudge(_ kind: InboxKind) async throws {
        let db = try AppDatabase.inMemory()
        let m = try stored(db, kind: kind)
        let poster = FakePoster(.notDetermined)
        #expect(await !ProactiveNotifier(db: db, poster: poster, enabled: { false }).notify(m))
        #expect(poster.all.isEmpty)
        #expect(poster.requests.withLock { $0 } == 0)  // nothing to notify: no prompt either
    }

    /// Reminders are the user's own: they notify whatever the proactive switch says.
    @Test func reminderStillPostsWithProactiveOff() async throws {
        let db = try AppDatabase.inMemory()
        let m = try stored(db, kind: .reminder, body: "Call the dentist")
        let poster = FakePoster(.authorized)
        #expect(await ProactiveNotifier(db: db, poster: poster, enabled: { false }).notify(m))
        #expect(poster.all.map(\.body) == ["Call the dentist"])
        #expect(try notifiedFlag(db, m.id!))
    }

    @Test func alreadyNotifiedMessageIsNotPostedTwice() async throws {
        let db = try AppDatabase.inMemory()
        let m = try stored(db, notified: true)
        let poster = FakePoster(.authorized)
        #expect(await !ProactiveNotifier(db: db, poster: poster, enabled: { true }).notify(m))
        #expect(poster.all.isEmpty)
    }

    @Test func previewsOffHideTheCapturedText() async throws {
        let db = try AppDatabase.inMemory()
        let m = try stored(db, body: "Marc wrote: send the password to bob@example.com")
        let poster = FakePoster(.authorized, previews: false)
        #expect(await ProactiveNotifier(db: db, poster: poster, enabled: { true }).notify(m))
        #expect(poster.all.map(\.body) == [ProactiveNotifications.hiddenBody])
        #expect(!poster.all[0].body.contains("Marc"))
    }

    @Test func bodyIsCutTo240CharactersOnOneLine() {
        let long = "**Today**\n\n" + String(repeating: "word ", count: 100)
        let body = ProactiveNotifications.body(long, previewsShown: true)
        #expect(body.count == ProactiveNotifications.maxBody)
        #expect(body.hasPrefix("Today word word"))
        #expect(body.hasSuffix("…"))
        #expect(!body.contains("\n"))
        #expect(ProactiveNotifications.body("  short  ", previewsShown: true) == "short")
    }

    @Test func unsavedMessageHasNoNotification() {
        let m = InboxMessage(kind: .nudge, title: "t", body: "b", dedupeKey: "k", createdAt: .now)
        #expect(ProactiveNotifications.content(for: m, previewsShown: true) == nil)
    }

    @Test func testNotificationNeedsAuthorizationOnly() async throws {
        let db = try AppDatabase.inMemory()
        let allowed = FakePoster(.authorized), denied = FakePoster(.denied)
        #expect(await ProactiveNotifier(db: db, poster: allowed, enabled: { false }).sendTest())
        #expect(allowed.all.count == 1 && allowed.all[0].inboxID == nil)
        #expect(await !ProactiveNotifier(db: db, poster: denied, enabled: { true }).sendTest())
        #expect(denied.all.isEmpty)
    }

    @Test func requestIfNeededAsksOnceAndRemembers() async throws {
        let db = try AppDatabase.inMemory()
        let poster = FakePoster(.notDetermined)
        let notifier = ProactiveNotifier(db: db, poster: poster, enabled: { true })
        #expect(await notifier.requestIfNeeded() == .authorized)
        #expect(await notifier.requestIfNeeded() == .authorized)
        #expect(poster.requests.withLock { $0 } == 1)
        #expect(try SettingsStore(db).value(Bool.self, forKey: ProactiveNotifications.askedKey) == true)
    }

    @Test func requestIfNeededSkipsWhenAlreadyAsked() async throws {
        let db = try AppDatabase.inMemory()
        try SettingsStore(db).setValue(true, forKey: ProactiveNotifications.askedKey)
        let poster = FakePoster(.notDetermined)
        #expect(await ProactiveNotifier(db: db, poster: poster, enabled: { true }).requestIfNeeded() == .notDetermined)
        #expect(poster.requests.withLock { $0 } == 0)
    }

    @Test func explicitRequestAsksEvenAfterNotNow() async throws {
        let db = try AppDatabase.inMemory()
        try SettingsStore(db).setValue(true, forKey: ProactiveNotifications.askedKey)
        let poster = FakePoster(.notDetermined)
        #expect(await ProactiveNotifier(db: db, poster: poster, enabled: { true }).request() == .authorized)
        #expect(poster.requests.withLock { $0 } == 1)
        // Already decided: macOS would not show the prompt again, so it is not asked.
        let denied = FakePoster(.denied)
        #expect(await ProactiveNotifier(db: db, poster: denied, enabled: { true }).request() == .denied)
        #expect(denied.requests.withLock { $0 } == 0)
    }

    @Test func cannotInterruptWhenIdleOrSharing() {
        #expect(ProactiveNotifications.canInterrupt(idleSeconds: 30, sharingScreen: false))
        #expect(ProactiveNotifications.canInterrupt(idleSeconds: 600, sharingScreen: false))
        #expect(!ProactiveNotifications.canInterrupt(idleSeconds: 601, sharingScreen: false))
        #expect(!ProactiveNotifications.canInterrupt(idleSeconds: 30, sharingScreen: true))
    }

    @Test func proactiveSwitchDefaultsOnAndPersists() throws {
        let db = try AppDatabase.inMemory()
        let s = SettingsStore(db)
        #expect(ProactiveSettings.enabled(s))
        try ProactiveSettings.setEnabled(false, s)
        #expect(!ProactiveSettings.enabled(s))
        #expect(try s.value(Bool.self, forKey: SettingRegistry.proactiveEnabledKey) == false)
    }

    @Test(arguments: [InboxKind.morningBrief, .eveningWrap])
    func briefNotificationIsHeldWhileSharingButStaysUnnotified(_ kind: InboxKind) async throws {
        let db = try AppDatabase.inMemory()
        let m = try stored(db, kind: kind)
        let poster = FakePoster(.notDetermined)
        let n = ProactiveNotifier(db: db, poster: poster, enabled: { true }, sharingScreen: { true })
        #expect(await !n.notify(m))
        #expect(poster.all.isEmpty)
        #expect(poster.requests.withLock { $0 } == 0)  // no permission prompt while sharing either
        #expect(try !notifiedFlag(db, m.id!))
    }

    @Test(arguments: [InboxKind.reminder, .nudge])
    func sharingDoesNotHoldRemindersOrNudgesAtTheNotifier(_ kind: InboxKind) async throws {
        // Nudges are gated earlier (the runner's canInterrupt); reminders always notify.
        let db = try AppDatabase.inMemory()
        let m = try stored(db, kind: kind)
        let poster = FakePoster(.authorized)
        #expect(await ProactiveNotifier(db: db, poster: poster, enabled: { true }, sharingScreen: { true }).notify(m))
        #expect(poster.all.count == 1)
        #expect(!ProactiveNotifications.heldWhileSharing(kind))
    }

    @Test func removeAllDeliveredReachesThePoster() async throws {
        let db = try AppDatabase.inMemory()
        let m = try stored(db, kind: .reminder)
        let poster = FakePoster(.authorized)
        let n = ProactiveNotifier(db: db, poster: poster, enabled: { false })
        #expect(await n.notify(m))
        await n.removeAllDelivered()
        #expect(poster.removals.withLock { $0 } == 1)
        #expect(poster.all.isEmpty)
    }
}

@Suite struct ProactiveInboxSwitchTests {
    /// A brief or nudge written before the switch was turned off is not delivered after it.
    @Test(arguments: [InboxKind.morningBrief, .eveningWrap, .nudge])
    func switchedOffMidRunDeliversNothing(_ kind: InboxKind) async throws {
        let db = try AppDatabase.inMemory()
        try ProactiveSettings.setEnabled(false, SettingsStore(db))
        let inbox = ProactiveInbox(db: db, onDelivered: { _ in })
        let stored = try await inbox.deliver(kind: kind, title: "t", body: "b", dedupeKey: "k", callIDs: [],
                                             expectedGeneration: nil, at: local("2026-11-20 10:00"))
        #expect(stored == nil)
        #expect(try await db.reader.read { d in try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM inbox_messages") } == 0)
        #expect(try ChatStore(db).turns(limit: 10).isEmpty)
    }

    @Test func remindersAreDeliveredWithProactiveOff() async throws {
        let db = try AppDatabase.inMemory()
        try ProactiveSettings.setEnabled(false, SettingsStore(db))
        let inbox = ProactiveInbox(db: db, onDelivered: { _ in })
        let stored = try await inbox.deliver(kind: .reminder, title: "Reminder", body: "b", dedupeKey: "k", callIDs: [],
                                             expectedGeneration: nil, at: local("2026-11-20 10:00"))
        #expect(stored != nil)
    }
}
