import AppKit
import Assistant
import Foundation
import UserNotifications
import os

/// `NotificationPosting` over `UNUserNotificationCenter`. It is the center's delegate: a
/// notification shows as a banner even while Remora is frontmost, and a click opens the chat on
/// the inbox message (`userInfo["inbox_id"]`). The permission prompt is shown only by `request()`
/// (onboarding, the launch path, or Settings), never by posting. Logs codes only.
final class SystemNotificationPoster: NSObject, NotificationPosting, UNUserNotificationCenterDelegate {
    static let inboxIDKey = "inbox_id"

    /// Opens the chat on a message; set once at wiring time, before any click can arrive.
    private let onOpen: @MainActor @Sendable (Int64) -> Void
    private static let log = Logger(subsystem: "dev.remora", category: "proactive")

    init(onOpen: @escaping @MainActor @Sendable (Int64) -> Void) {
        self.onOpen = onOpen
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func status() async -> NotificationAuth {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: .authorized
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    func previewsShown() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().showPreviewsSetting != .never
    }

    func request() async -> Bool {
        do { return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) } catch {
            Self.log.error("notification request failed: \((error as NSError).code, privacy: .public)")
            return false
        }
    }

    func post(_ n: ProactiveNotification) async {
        let content = UNMutableNotificationContent()
        content.title = n.title
        content.body = String(n.body.prefix(ProactiveNotifications.maxBody))
        content.threadIdentifier = n.thread
        content.sound = .default
        if let id = n.inboxID { content.userInfo = [Self.inboxIDKey: id] }
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: n.id, content: content, trigger: nil))
        } catch {
            Self.log.error("notification not posted: \((error as NSError).code, privacy: .public)")
        }
    }

    func removeAllDelivered() async {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let id = (response.notification.request.content.userInfo[Self.inboxIDKey] as? NSNumber)?.int64Value
        else { return }
        let onOpen = onOpen
        await MainActor.run { onOpen(id) }
    }
}
