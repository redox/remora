import AppKit
import Lifecycle
import SwiftUI

struct GeneralSettingsView: View {
    let env: AppEnvironment

    var body: some View {
        let login = env.loginItem
        Form {
            Toggle("Open at login", isOn: Binding(
                get: { login.isEnabled }, set: { login.userSet($0) }))
                .disabled(!login.isEnabled && !login.canEnable)
            if !login.canEnable {
                Text(LaunchCopy.loginItemNotInstalled)
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if login.needsApproval {
                Text("Approve Remora in System Settings › General › Login Items.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let message = login.errorMessage {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
            updatesSection
            Section {
                Button("Show onboarding again") { env.showOnboarding() }
                Button("Acknowledgements") { AcknowledgementsWindow.show() }
            }
        }
        .formStyle(.grouped)
        .onAppear { login.refresh() }
    }

    @ViewBuilder private var updatesSection: some View {
        let updater = env.updater
        Section("Updates") {
            Text(UpdateCopy.versionLine(short: Self.bundleString("CFBundleShortVersionString"),
                                        build: Self.bundleString("CFBundleVersion")))
            if case .disabled(let reason) = updater.state {
                Text(UpdateCopy.disabledCaption(reason))
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Toggle(UpdateCopy.automaticToggle, isOn: Binding(
                    get: { updater.automaticallyInstalls }, set: { updater.automaticallyInstalls = $0 }))
                if let item = updater.menuItem(busy: env.isBusyForUpdate) {
                    Button(item.title) {
                        switch item.action {
                        case .check: updater.checkForUpdates()
                        case .installNow: updater.installNow()
                        }
                    }
                    .disabled(!item.enabled)
                }
                Text(UpdateCopy.caption)
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private static func bundleString(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "?"
    }
}

/// Shows the bundled `THIRD-PARTY-NOTICES.md` read-only, in Remora's own window: opening the
/// bundle's copy in another app could let that app edit a file inside the signed bundle.
@MainActor
enum AcknowledgementsWindow {
    private static var window: NSWindow?

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let text = Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "md")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? "The third-party notices are missing from this copy of Remora."

        let scroll = NSTextView.scrollableTextView()
        if let textView = scroll.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            textView.textContainerInset = NSSize(width: 12, height: 12)
            textView.string = text
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Acknowledgements"
        window.contentView = scroll
        window.isReleasedWhenClosed = false
        window.center()
        Self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
