import AppKit
import Dictation
import SwiftUI

/// Optional dictation (off by default). Turning it on saves `DictationSettings.enabled`, asks for the
/// microphone and starts the default language's speech model download when it is missing.
struct DictationStep: View {
    let env: AppEnvironment

    private var dictation: DictationController { env.dictation }

    private var enabled: Binding<Bool> {
        Binding(get: { dictation.settings.enabled }, set: { on in
            var s = dictation.settings
            s.enabled = on
            dictation.update(s)
            if on { Task { await prepare() } }
        })
    }

    private func prepare() async {
        await env.permissions.requestMicrophone()
        let assets = env.speechAssets
        await assets.refresh()
        await assets.install(dictation.settings.defaultLocale)  // returns at once when installed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Dictation (optional)").font(.title2.bold())
            Text("Hold the rewrite key and talk. Review the live transcript, then choose Insert or Edit.")
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Turn on dictation", isOn: enabled)
            if dictation.settings.enabled {
                HStack {
                    if env.permissions.microphone == .granted {
                        Label("Microphone: Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Label("Microphone: Not allowed", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                        Button("Open System Settings") { env.permissions.openMicrophoneSettings() }
                    }
                }
            }
        }
    }
}
