import AppKit
import Assistant
import Capture
import Foundation
import LLM
import Memory
import Observation
import os
import Retrieval
import Storage

/// Briefs, nudges and reminders in the running app.
///
/// - Briefs and nudges run as `MemoryScheduler` jobs (`runners` + `ProactivePlanner`, wired by
///   `AppEnvironment` before the scheduler exists). They deliver through one `ProactiveInbox`
///   whose `onDelivered` lands here: the chat reloads and `ProactiveNotifier` posts the macOS
///   notification when proactive messages are on and macOS allows it.
/// - Reminders fire from `ReminderTimer` (the single caller of `ReminderDispatcher.fire()`).
/// - The chat is pruned to 90 days at launch, then every 24 h (`ChatRetention`).
/// - Reminders always notify; briefs and nudges only while proactive messages are on.
/// - The notification prompt is never shown at launch: it comes once, with the first message
///   about to notify, or from onboarding or Settings.
///
/// Never logs titles, bodies or reminder text.
@MainActor @Observable
final class ProactiveController {
    private(set) var notificationAuth: NotificationAuth = .notDetermined
    /// `proactive.enabled`, live: runners and the planner read the stored value fresh.
    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            do { try ProactiveSettings.setEnabled(enabled, SettingsStore(db)) } catch {
                Self.log.error("proactive setting not saved: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    @ObservationIgnored private let db: AppDatabase
    @ObservationIgnored private let notifier: ProactiveNotifier
    @ObservationIgnored private let timer: ReminderTimer
    @ObservationIgnored private let chat: ChatModel
    @ObservationIgnored private var pruneTimer: Timer?
    @ObservationIgnored private var started = false
    @ObservationIgnored nonisolated private static let log = Logger(subsystem: "dev.remora", category: "proactive")

    init(db: AppDatabase, inbox: ProactiveInbox, poster: any NotificationPosting, reminders: ReminderEngine,
         agent: any ReminderAnswering, chat: ChatModel) {
        self.db = db; self.chat = chat
        let settings = SettingsStore(db)
        enabled = ProactiveSettings.enabled(settings)
        // A brief's notification is held while the screen is shared (the gate nudges use).
        notifier = ProactiveNotifier(db: db, poster: poster, enabled: { ProactiveSettings.enabled(settings) },
                                     sharingScreen: { await ScreenShareMonitor.isSharingNow() })
        timer = ReminderTimer(dispatcher: ReminderDispatcher(engine: reminders, inbox: inbox, agent: agent),
                              engine: reminders)
    }

    // MARK: - Wiring (static: built before the scheduler and this controller exist)

    /// The proactive job runners for `MemoryScheduler`: the morning brief, the evening wrap-up and
    /// the nudge scan. Each reads the proactive switch fresh; a nudge is held while the user is
    /// idle over 600 s or sharing the screen.
    nonisolated static func runners(db: AppDatabase, llm: LLMService, inbox: ProactiveInbox) -> [JobKind: any JobRunner] {
        ProactiveRunners.make(db: db, llm: llm, inbox: inbox, policy: { SnapshotPolicy.current(db) },
                              canInterrupt: { await canInterrupt() })
    }

    /// Plans briefs and nudges (nothing while proactive or background memory is off).
    nonisolated static func planner(db: AppDatabase, calendar: Calendar) -> ProactivePlanner {
        let settings = SettingsStore(db)
        return ProactivePlanner(db: db, calendar: calendar, enabled: { ProactiveSettings.enabled(settings) })
    }

    nonisolated static func canInterrupt() async -> Bool {
        let idle = SystemSignals.idleSeconds()
        guard idle <= ProactiveNotifications.maxIdle else { return false }
        return ProactiveNotifications.canInterrupt(idleSeconds: idle, sharingScreen: await ScreenShareMonitor.isSharingNow())
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        timer.start()
        pruneChat()
        let prune = Timer(timeInterval: ChatRetention.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pruneChat() }
        }
        prune.tolerance = 600
        RunLoop.main.add(prune, forMode: .common)
        pruneTimer = prune
        // Status only: the prompt is never shown at launch (first notifying delivery, onboarding
        // or Settings ask instead; `ProactiveNotifier.notify`).
        Task { [weak self] in
            guard let self else { return }
            notificationAuth = await notifier.status()
        }
    }

    /// The proactive inbox delivered a message (any thread): show it in the chat, then notify.
    /// The first message about to notify asks for permission once.
    func delivered(_ m: InboxMessage) async {
        chat.reload()
        _ = await notifier.notify(m)
        notificationAuth = await notifier.status()
    }

    /// Delete-all succeeded: clears delivered notifications (their bodies quote wiped messages),
    /// stops the running chat turn and reloads the chat, and re-arms the reminder timer.
    func dataDeleted() async {
        await notifier.removeAllDelivered()
        await chat.dataDeleted()
        remindersChanged()
    }

    /// A chat action, Settings or onboarding changed reminders: re-arm the timer.
    func remindersChanged() { timer.rearm() }

    /// A chat action changed `proactive_messages` in storage.
    func reloadEnabled() {
        let stored = ProactiveSettings.enabled(SettingsStore(db))
        if stored != enabled { enabled = stored }
    }

    // MARK: - Notifications

    /// Once (`notifications.asked`): the launch path and onboarding's "Allow notifications".
    func requestNotificationsIfNeeded() async {
        notificationAuth = await notifier.requestIfNeeded()
    }

    /// An explicit "Allow notifications" (Settings): prompts whenever macOS has not decided yet.
    func requestNotifications() async {
        notificationAuth = await notifier.request()
    }

    /// Onboarding's "Not now": never prompt at launch.
    func declineNotifications() { notifier.markAsked() }

    func refreshNotificationAuth() async {
        notificationAuth = await notifier.status()
    }

    func sendTestNotification() async {
        _ = await notifier.sendTest()
        notificationAuth = await notifier.status()
    }

    // MARK: - Private

    private func pruneChat() {
        let db = db
        Task.detached(priority: .utility) {
            do {
                if let removed = try ChatRetention.pruneIfDue(db: db, now: .now) {
                    Self.log.info("chat pruned \(removed, privacy: .public) rows")
                }
            } catch {
                Self.log.error("chat prune failed: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

}
