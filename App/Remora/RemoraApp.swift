import Indicator
import os
import Storage
import SwiftUI

@main
struct RemoraApp: App {
    @State private var env: AppEnvironment?
    @State private var updater: UpdaterController

    init() {
        LaunchGate.run()
        // Independent of the database, so a broken database can still be fixed by an update.
        // No Sparkle updater exists unless the configuration is `.ready` (never in Debug or outside Applications).
        let probe = BusyProbe()
        let updater = UpdaterController(configuration: UpdaterController.configuration(),
                                        isBusy: { probe.env?.isBusyForUpdate ?? false },
                                        idleSeconds: { SystemSignals.idleSeconds() })
        _updater = State(initialValue: updater)
        do {
            let env = AppEnvironment(db: try .open(at: AppDatabase.defaultURL), updater: updater)
            probe.env = env
            _env = State(initialValue: env)
        } catch {
            Logger(subsystem: "dev.remora", category: "app")
                .error("database open failed: \(String(describing: type(of: error)), privacy: .public)")
            _env = State(initialValue: nil)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(env: env, updater: updater)
        } label: {
            MenuBarLabel(env: env)
        }
        Settings {
            if let env { SettingsView(env: env) } else { Text("Database unavailable.").padding() }
        }
    }
}

/// Lets the updater ask whether Remora is busy without owning the environment (nil when the database failed).
@MainActor
private final class BusyProbe {
    weak var env: AppEnvironment?
}

/// The menu-bar icon. Always alive, so it also hands `openSettings` to the environment.
private struct MenuBarLabel: View {
    let env: AppEnvironment?
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    var body: some View {
        if let env {
            let meeting = env.meetingRecording.recordingClientName
            let dictating = env.dictation.phase == .listening
            let recording = meeting != nil || dictating
            let pulsing = recording && !reduceMotion
            let windowStatus = IndicatorCopy.headline(env.indicator.state) ?? env.statusText
            let label = [meeting.map { "Recording \($0)" }, dictating ? "Recording dictation" : nil, windowStatus]
                .compactMap { $0 }.joined(separator: ". ")
            Image(nsImage: MenuBarIcon.image(symbol: env.menuBarSymbol, dot: env.isPaused ? nil : env.indicator.dot,
                                             recording: recording ? (pulsing && dimmed ? .dim : .bright) : .off))
                .accessibilityLabel(label)
                .task(id: pulsing) {
                    dimmed = false
                    while pulsing && !Task.isCancelled {
                        do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
                        dimmed.toggle()
                    }
                }
                .onAppear { env.settingsOpener = { openSettings() } }
        } else {
            Image(systemName: "exclamationmark.triangle")
        }
    }
}
