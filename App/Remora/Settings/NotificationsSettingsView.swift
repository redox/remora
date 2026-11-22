import AppKit
import Assistant
import SwiftUI

extension NotificationAuth {
    var title: String {
        switch self {
        case .notDetermined: "Not asked yet"
        case .authorized: "Allowed"
        case .denied: "Not allowed"
        }
    }
}

/// Settings › Notifications. Authorization is requested only from the user's click
/// (`ProactiveController.requestNotifications()`), never on its own.
struct NotificationsSettingsView: View {
    let env: AppEnvironment
    @State private var testStatus: String?

    static let systemSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=dev.remora.Remora")!

    /// Pinned copy; the nudge cap comes from the planner so the two can't drift.
    static let proactiveCaption = "A morning brief around 8:00, an evening wrap-up around 16:00, and at most \(ProactivePlanner.dailyNudgeCap) nudges a day. New recurring routines appear in chat. When off, chat still works, and reminders still notify (they are yours)."

    var body: some View {
        let proactive = env.proactive
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Proactive messages", isOn: Binding(get: { proactive.enabled }, set: { proactive.enabled = $0 }))
                    Text(Self.proactiveCaption).font(.footnote).foregroundStyle(.secondary)
                }
                if proactive.enabled, !env.memory.enabled {
                    HStack {
                        Label("Needs Background memory (Settings › Memory)", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open Memory") { env.settingsTab = .memory }
                    }
                }
            }
            Section {
                LabeledContent("macOS notifications") {
                    HStack {
                        Text(proactive.notificationAuth.title)
                            .foregroundStyle(proactive.notificationAuth == .authorized ? .green : .secondary)
                        if proactive.notificationAuth == .notDetermined {
                            Button("Allow notifications") { Task { await proactive.requestNotifications() } }
                        } else {
                            Button("Open System Settings") { NSWorkspace.shared.open(Self.systemSettingsURL) }
                        }
                    }
                }
                HStack {
                    Button("Send a test notification") {
                        Task {
                            await proactive.sendTestNotification()
                            testStatus = proactive.notificationAuth == .authorized ? "Sent." : "Allow notifications first."
                        }
                    }
                    if let testStatus { Text(testStatus).font(.footnote).foregroundStyle(.secondary) }
                }
                Text("Briefs that arrive while your Mac sleeps are delivered when it wakes: the morning brief until noon, the evening wrap-up until midnight.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await proactive.refreshNotificationAuth() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await proactive.refreshNotificationAuth() }
        }
    }
}
