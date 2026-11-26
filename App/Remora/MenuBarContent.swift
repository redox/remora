import AppKit
import Dictation
import Indicator
import Lifecycle
import LLM
import Storage
import SwiftUI

struct MenuBarContent: View {
    let env: AppEnvironment?
    let updater: UpdaterController

    var body: some View {
        if let env {
            if env.meetingRecording.enabled {
                Text(env.meetingRecording.displayStatus)
                if env.meetingRecording.canStop {
                    Button("Stop meeting recording") { env.meetingRecording.stop() }
                }
            } else {
                Button("Set up meeting recording…") { env.openSettings(tab: .meetingSources) }
            }
            Divider()
            if let headline = IndicatorCopy.headline(env.indicator.state) { Text(headline) }
            let items = QuickMenu.items(for: env.indicator.state)
            ForEach(items, id: \.self) { item in
                Button(item.title) { env.perform(item) }
                    .disabled(env.isDeletingAll)
            }
            if QuickMenu.needsResumeFallback(isPaused: env.isPaused, items: items) {
                Button("Resume") { env.resume() }
                    .disabled(env.isDeletingAll)
            }
            Divider()
            Text(env.statusText)
                .onAppear { env.refresh() }
            if let line = env.rewrite.statusLine { Text(line) }
            if case .listening = env.dictation.phase, let locale = env.dictation.sessionLocale {
                Text("Listening (\(locale.name))")
            }
            if let error = env.lastError { Text(error) }
            Text(env.account.presentation.menuLine)
                .onAppear { Task { await env.account.refreshState() } }
            if env.account.presentation.offersContinue {
                Button("Continue with ChatGPT…") { env.continueWithChatGPT() }
            }
            Divider()
            if !env.permissions.accessibilityGranted {
                Button("Grant Accessibility…") { env.showOnboarding() }
            }
            if env.dictation.settings.enabled {
                Menu("Dictation language") {
                    languageItem("Automatic", pinned: nil)
                    ForEach(DictationLocale.allCases, id: \.self) { languageItem($0.name, pinned: $0) }
                }
            }
            Menu("Pause") {
                ForEach(PauseDuration.allCases, id: \.self) { duration in
                    Button(duration.title) { env.pause(for: duration) }
                }
            }
            .disabled(env.isDeletingAll)
            Divider()
            Button("Open chat") { env.bar.toggle() }
            Button("Settings…") { env.openSettings(tab: .general) }
            .keyboardShortcut(",")
            updateItem(busy: env.isBusyForUpdate)
        } else {
            Text("Database unavailable")
            updateItem(busy: false)
        }
        Button("Quit Remora") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// Hidden while updates are off (Debug, outside Applications, or a build without a feed and key).
    @ViewBuilder
    private func updateItem(busy: Bool) -> some View {
        if let item = updater.menuItem(busy: busy) {
            Button(item.title) {
                switch item.action {
                case .check: updater.checkForUpdates()
                case .installNow: updater.installNow()
                }
            }
            .disabled(!item.enabled)
        }
    }

    @ViewBuilder
    private func languageItem(_ title: String, pinned: DictationLocale?) -> some View {
        if let env {
            Toggle(title, isOn: Binding(get: { env.dictation.settings.pinnedLocale == pinned },
                                        set: { _ in env.dictation.setPinned(pinned) }))
        }
    }
}
