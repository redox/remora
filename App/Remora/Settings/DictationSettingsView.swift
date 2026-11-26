import AppKit
import Dictation
import SwiftUI

/// Settings › Dictation. Every change goes through `DictationController.update`, which saves it and
/// applies it live. Shows only counts and statuses, never transcripts, app keys or language memory keys.
struct DictationSettingsView: View {
    let env: AppEnvironment

    @State private var transcriptionKey = ""
    @State private var transcriptionKeyError: String?

    private var dictation: DictationController { env.dictation }
    private var assets: SpeechAssetModel { env.speechAssets }
    private var settings: DictationSettings { dictation.settings }

    private func binding<T>(_ keyPath: WritableKeyPath<DictationSettings, T>) -> Binding<T> {
        Binding(get: { dictation.settings[keyPath: keyPath] }, set: { value in
            var s = dictation.settings
            s[keyPath: keyPath] = value
            dictation.update(s)
        })
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { settings.enabled }, set: { on in
            var s = settings
            s.enabled = on
            dictation.update(s)
            if on { Task { await prepare() } }
        })
    }

    /// Turned on: ask for the microphone when it was never asked, then fetch the missing speech models.
    private func prepare() async {
        if env.permissions.microphone == .notDetermined { await env.permissions.requestMicrophone() }
        await assets.refresh()
        await assets.installMissing()
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enable voice dictation", isOn: enabledBinding)
            }
            Section("Shortcut") {
                Text("Hold the rewrite key to dictate and release to review. Press Return in Insert to draft from your prompt, or choose Insert transcript to use your words.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("For hands-free dictation, tap the key to open the popover and choose Record.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Mac speech language") {
                Picker("Default language", selection: binding(\.defaultLocale)) {
                    ForEach(DictationLocale.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                HStack {
                    let n = dictation.rememberedLanguageCount
                    Text("Remora remembers the last language you used in each app (\(n) \(n == 1 ? "app" : "apps")).")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button("Forget") { dictation.forgetRememberedLanguages() }
                        .disabled(n == 0)
                }
            }
            Section("OpenAI transcription") {
                LabeledContent("Status", value: dictation.hasTranscriptionKey ? "Key saved" : "On this Mac")
                VStack(alignment: .leading, spacing: 6) {
                    Text("OpenAI API key").accessibilityHidden(true)
                    SecureField("OpenAI API key", text: $transcriptionKey,
                                prompt: Text(dictation.hasTranscriptionKey ? "Paste a replacement key" : "Paste your API key"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .accessibilityLabel("OpenAI API key")
                }
                HStack {
                    Button(dictation.hasTranscriptionKey ? "Replace key" : "Save and enable") {
                        transcriptionKeyError = dictation.saveTranscriptionKey(transcriptionKey)
                        if transcriptionKeyError == nil { transcriptionKey = "" }
                    }
                    .disabled(OpenAITranscription.normalizedKey(transcriptionKey) == nil)
                    if dictation.hasTranscriptionKey {
                        Button("Remove key") {
                            transcriptionKeyError = dictation.removeTranscriptionKey()
                            transcriptionKey = ""
                        }
                    }
                }
                Text("Saving a key sends eligible dictation audio to OpenAI when you choose Insert transcript. The live preview and dictation fallback use this Mac.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("If automatic meeting recording is on, Remora also sends eligible meeting app audio and your unmuted microphone to OpenAI for language detection and transcription. Both features use your API project. The key is stored in Keychain.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let transcriptionKeyError { Text(transcriptionKeyError).foregroundStyle(.red) }
            }
            Section("Cleanup") {
                Toggle("Clean up transcripts", isOn: binding(\.cleanupEnabled))
                Text(Self.cleanupCaption).font(.footnote).foregroundStyle(.secondary)
            }
            Section("Speech models") {
                ForEach(DictationLocale.allCases, id: \.self) { locale in
                    SpeechModelRow(locale: locale, state: assets.state(locale)) {
                        Task { await assets.install(locale) }
                    }
                }
            }
            Section("Microphone") {
                LabeledContent("Status") {
                    Text(Self.microphoneLabel(env.permissions.microphone))
                        .foregroundStyle(env.permissions.microphone == .granted ? .green : .secondary)
                }
                switch env.permissions.microphone {
                case .notDetermined:
                    Button("Allow…") { Task { await env.permissions.requestMicrophone() } }
                case .denied, .restricted:
                    Button("Open System Settings") { env.permissions.openMicrophoneSettings() }
                case .granted:
                    EmptyView()
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            env.permissions.poll()
            dictation.refreshTranscriptionKeyStatus()
        }
        .onDisappear { transcriptionKey = "" }
        .task { await assets.refresh() }
        .task(id: downloading) {
            // A download keeps running without us: re-read it until it settles (progress, then Installed).
            while downloading, !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                await assets.refresh()
            }
        }
    }

    private var downloading: Bool {
        DictationLocale.allCases.contains { if case .installing = assets.state($0) { true } else { false } }
    }

    static let cleanupCaption = "Removes filler words and fixes punctuation with your ChatGPT plan's small model. In apps Remora doesn't capture, only the on-device model is used, and if it's unavailable the transcript goes in as heard. Turn it off to insert the transcript without cleanup. Corrections you make in the preview are kept as typed."

    static func microphoneLabel(_ status: MicrophoneStatus) -> String {
        switch status {
        case .granted: "Allowed"
        case .denied, .restricted: "Not allowed"
        case .notDetermined: "Not asked yet"
        }
    }
}

struct SpeechModelRow: View {
    let locale: DictationLocale
    let state: AssetState
    let action: () -> Void

    var body: some View {
        LabeledContent("\(locale.name) (\(locale.rawValue))") {
            switch state {
            case .installed:
                Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .installing(let p):
                HStack {
                    Text(p.map { "Downloading… \(Int(($0 * 100).rounded(.down)))%" } ?? "Downloading…")
                    ProgressView(value: p).frame(width: 80)
                }
            case .unknown, .notInstalled:
                HStack { Text("Not installed").foregroundStyle(.secondary); Button("Download", action: action) }
            case .failed(let message):
                HStack { Text("Failed: \(message)").foregroundStyle(.red); Button("Retry", action: action) }
            case .unsupported:
                Text("Not supported on this Mac").foregroundStyle(.secondary)
            }
        }
    }
}
