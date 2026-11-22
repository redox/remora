import Foundation
import Storage
import os

/// macOS notification permission, as Remora shows it.
public enum NotificationAuth: String, Sendable, Equatable {
    case notDetermined, denied, authorized
}

/// One macOS notification. `id` replaces an earlier one with the same id; `thread` groups by kind.
public struct ProactiveNotification: Sendable, Equatable {
    public var id: String
    public var title: String
    public var body: String
    public var thread: String
    /// The inbox message a click opens (nil for the test notification).
    public var inboxID: Int64?

    public init(id: String, title: String, body: String, thread: String, inboxID: Int64?) {
        self.id = id; self.title = title; self.body = body; self.thread = thread; self.inboxID = inboxID
    }
}

/// Posts macOS notifications. The app's `SystemNotificationPoster` wraps `UNUserNotificationCenter`;
/// tests use a fake and never post a real notification.
public protocol NotificationPosting: Sendable {
    func status() async -> NotificationAuth
    /// False when the user set macOS "Show previews" to Never: the body then carries no content.
    func previewsShown() async -> Bool
    /// Shows the macOS permission prompt (`.alert`, `.sound`); true when allowed.
    func request() async -> Bool
    func post(_ n: ProactiveNotification) async
    /// Removes every delivered and pending Remora notification (delete-all: their bodies quote
    /// briefs, nudges and reminders).
    func removeAllDelivered() async
}

/// The proactive on/off switch (Settings › Notifications "Proactive messages", pinned key
/// `proactive.enabled`, default on). Read fresh by every runner, planner and the notifier.
public enum ProactiveSettings {
    public static func enabled(_ s: SettingsStore) -> Bool {
        (try? s.value(Bool.self, forKey: SettingRegistry.proactiveEnabledKey)) ?? true
    }

    public static func setEnabled(_ on: Bool, _ s: SettingsStore) throws {
        try s.setValue(on, forKey: SettingRegistry.proactiveEnabledKey)
    }
}

/// Pure notification rules.
public enum ProactiveNotifications {
    public static let maxBody = 240
    /// The body when macOS previews are off: never the message's (captured or derived) text.
    public static let hiddenBody = "Open Remora to read it."
    /// Set once the launch or onboarding prompt was shown (or declined with "Not now").
    public static let askedKey = "notifications.asked"
    /// Nudges are held when the user has been idle longer than this (pinned).
    public static let maxIdle: TimeInterval = 600

    /// The notification for a stored message; nil for an unsaved one.
    public static func content(for m: InboxMessage, previewsShown: Bool) -> ProactiveNotification? {
        guard let id = m.id else { return nil }
        return ProactiveNotification(id: "inbox-\(id)", title: m.title, body: body(m.body, previewsShown: previewsShown),
                                     thread: m.kind.rawValue, inboxID: id)
    }

    /// One line, bold markers dropped, at most `maxBody` characters (ending "…" when cut). With
    /// previews off, `hiddenBody`.
    public static func body(_ text: String, previewsShown: Bool) -> String {
        guard previewsShown else { return hiddenBody }
        let flat = text.replacingOccurrences(of: "**", with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > maxBody else { return flat }
        return String(flat.prefix(maxBody - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Whether a delivered message gets a notification at all: reminders are the user's own and
    /// always do; briefs and nudges only while proactive messages are on.
    public static func wantsNotification(_ kind: InboxKind, proactiveEnabled: Bool) -> Bool {
        kind == .reminder || proactiveEnabled
    }

    /// A brief's notification is held while the screen is shared (the same gate nudges use); the
    /// brief still lands in the chat. Reminders are the user's own and always notify.
    public static func heldWhileSharing(_ kind: InboxKind) -> Bool {
        kind == .morningBrief || kind == .eveningWrap
    }

    /// A nudge may interrupt only an active user (idle ≤ 600 s) who is not sharing the screen.
    public static func canInterrupt(idleSeconds: TimeInterval, sharingScreen: Bool) -> Bool {
        idleSeconds <= maxIdle && !sharingScreen
    }
}

/// Posts the notification for a delivered inbox message (`ProactiveInbox.onDelivered`) and
/// handles the permission prompt.
/// - Reminders always notify; briefs and nudges only while proactive messages are on.
/// - Automatic routine findings are inbox-only and never request notification permission.
/// - The prompt is never shown at launch: the first message about to notify asks once
///   (`notifications.asked`), as do onboarding and Settings.
/// - Denied (or declined) posts nothing; the message is still in the chat.
/// Never logs titles or bodies.
public struct ProactiveNotifier: Sendable {
    public static let testTitle = "Remora"
    public static let testBody = "Notifications are on. Briefs, nudges and reminders will appear like this."

    private let db: AppDatabase
    private let poster: any NotificationPosting
    private let enabled: @Sendable () -> Bool
    private let sharingScreen: @Sendable () async -> Bool
    private static let log = Logger(subsystem: "dev.remora", category: "proactive")

    public init(db: AppDatabase, poster: any NotificationPosting, enabled: @escaping @Sendable () -> Bool,
                sharingScreen: @escaping @Sendable () async -> Bool = { false }) {
        self.db = db; self.poster = poster; self.enabled = enabled; self.sharingScreen = sharingScreen
    }

    /// Posts once per message, then sets `notified`. Returns whether it posted.
    @discardableResult
    public func notify(_ m: InboxMessage) async -> Bool {
        guard !m.isRoutineFinding, ProactiveNotifications.wantsNotification(m.kind, proactiveEnabled: enabled()),
              !m.notified else { return false }
        if ProactiveNotifications.heldWhileSharing(m.kind), await sharingScreen() {
            Self.log.info("notification held while sharing: \(m.kind.rawValue, privacy: .public)")
            return false
        }
        var auth = await poster.status()
        if auth == .notDetermined { auth = await requestIfNeeded() }
        guard auth == .authorized,
              let n = ProactiveNotifications.content(for: m, previewsShown: await poster.previewsShown()),
              let id = m.id else { return false }
        await poster.post(n)
        do { try InboxStore(db).setNotified(id) } catch {
            Self.log.error("notified flag not saved: \(String(describing: type(of: error)), privacy: .public)")
        }
        Self.log.info("notification posted: \(m.kind.rawValue, privacy: .public)")
        return true
    }

    /// Settings › Notifications "Send a test notification" (works with proactive off).
    public func sendTest() async -> Bool {
        guard await poster.status() == .authorized else { return false }
        await poster.post(ProactiveNotification(id: "test-\(UUID().uuidString)", title: Self.testTitle,
                                                body: Self.testBody, thread: "test", inboxID: nil))
        return true
    }

    public func status() async -> NotificationAuth { await poster.status() }

    /// Delete-all: clears Remora's delivered and pending notifications.
    public func removeAllDelivered() async { await poster.removeAllDelivered() }

    /// The launch / onboarding path: asks at most once (`notifications.asked`).
    public func requestIfNeeded() async -> NotificationAuth {
        let asked = (try? SettingsStore(db).value(Bool.self, forKey: ProactiveNotifications.askedKey)) ?? false
        guard !asked else { return await poster.status() }
        return await request()
    }

    /// An explicit user action ("Allow notifications"): prompts when macOS has not decided yet,
    /// and records that the user was asked.
    public func request() async -> NotificationAuth {
        if await poster.status() == .notDetermined { _ = await poster.request() }
        markAsked()
        return await poster.status()
    }

    /// "Not now" in onboarding: never prompt at launch.
    public func markAsked() {
        do { try SettingsStore(db).setValue(true, forKey: ProactiveNotifications.askedKey) } catch {
            Self.log.error("notifications.asked not saved: \(String(describing: type(of: error)), privacy: .public)")
        }
    }
}
