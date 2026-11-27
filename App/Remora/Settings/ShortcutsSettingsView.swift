import AppKit
import Input
import SwiftUI

/// Settings › Shortcuts: the rewrite key, Rewrite-mode gestures, the fallback chord and sounds.
/// Every change is saved and applied at once.
struct ShortcutsSettingsView: View {
    let rewrite: RewriteController
    let openDictationSettings: () -> Void

    private func binding<T>(_ keyPath: WritableKeyPath<ShortcutSettings, T>) -> Binding<T> {
        Binding(get: { rewrite.shortcuts[keyPath: keyPath] }, set: { value in
            var s = rewrite.shortcuts
            s[keyPath: keyPath] = value
            rewrite.updateShortcuts(s)
        })
    }

    var body: some View {
        let s = rewrite.shortcuts
        Form {
            Section("Rewrite key") {
                Toggle("Rewrite key", isOn: binding(\.rewriteKeyEnabled))
                Picker("Key", selection: binding(\.trigger)) {
                    ForEach(TriggerKey.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .disabled(!s.rewriteKeyEnabled)
                Text("Tap to open Draft at the cursor or Rewrite when text is selected. Double-tap to rewrite selected text or draft at the caret.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let status = rewrite.statusLine {
                    Text(status).font(.footnote).foregroundStyle(.orange)
                }
            }
            Section("Writing popover") {
                Toggle("Double-tap writes in place", isOn: binding(\.doubleTapRewrites))
                Toggle("Hold opens the popover", isOn: binding(\.holdOpensEdit))
                Text("With dictation enabled, holding records speech. Tap the key while the popover is open to switch between Draft and Rewrite.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .disabled(!s.rewriteKeyEnabled)
            Section("Fallback shortcut") {
                Toggle("Shortcut", isOn: binding(\.chordEnabled))
                LabeledContent("Rewrite with") {
                    ChordRecorder(chord: s.chord, onRecord: { chord in
                        var next = rewrite.shortcuts
                        next.chord = chord
                        rewrite.updateShortcuts(next)
                    }, onRecording: { rewrite.setChordSuspended($0) })
                }
                .disabled(!s.chordEnabled)
                Text("Off by default. While on, the shortcut is taken from every app: ⇧⌘G is also Find Previous and Finder's Go to Folder.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let error = rewrite.chordError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
            Section("Dictation") {
                Button("Dictation settings…", action: openDictationSettings)
            }
            Section("Sounds") {
                Toggle("Play sounds", isOn: binding(\.soundsEnabled))
            }
            Section {
                Text("Quit Goldfish while using Remora: both use right ⌥.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { rewrite.refreshSecureInput() }
    }
}

/// Click, then press the new shortcut (it needs ⌘, ⌃ or ⌥). Esc cancels.
private struct ChordRecorder: View {
    let chord: KeyChord
    let onRecord: (KeyChord) -> Void
    let onRecording: (Bool) -> Void

    @State private var recording = false
    @State private var hint: String?
    @State private var monitor: Any?

    var body: some View {
        HStack {
            if let hint { Text(hint).font(.footnote).foregroundStyle(.secondary) }
            Button(recording ? "Press a shortcut…" : ChordName.string(chord)) {
                recording ? stop() : start()
            }
            .monospaced()
        }
        .onDisappear { stop() }
    }

    private func start() {
        hint = nil
        recording = true
        onRecording(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handle(event) }
            return nil  // swallowed while recording
        }
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53, flags.subtracting([.capsLock, .function, .numericPad]).isEmpty {
            stop()
            return
        }
        let chord = KeyChord(keyCode: UInt32(event.keyCode), command: flags.contains(.command), shift: flags.contains(.shift),
                             option: flags.contains(.option), control: flags.contains(.control))
        guard chord.isUsableHotKey else {
            hint = "Use ⌘, ⌃ or ⌥ with a key"
            return
        }
        stop()
        onRecord(chord)
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { onRecording(false) }
        recording = false
    }
}
