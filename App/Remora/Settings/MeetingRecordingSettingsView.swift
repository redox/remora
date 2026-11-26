import Dictation
import SwiftUI

struct MeetingRecordingSettingsView: View {
    let env: AppEnvironment
    private var recorder: MeetingRecordingController { env.meetingRecording }
    private var usesOpenAI: Bool { env.dictation.hasTranscriptionKey }

    var body: some View {
        Section("Meeting recording") {
            Text("Record joined Google Meet, Zoom and Teams calls. Remora captures the meeting app’s audio and your microphone while the meeting shows it is unmuted. Meet recordings can include audio playing in other Chrome tabs.")
                .font(.callout).foregroundStyle(.secondary)
            LabeledContent("Transcription", value: usesOpenAI ? "OpenAI" : "Apple Speech on this Mac")
            if usesOpenAI {
                Text("Remora sends eligible meeting audio to OpenAI in segments using the API key in Dictation settings. OpenAI detects the language. Charges apply to your API project.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Choose a meeting language for on-device transcription. Saving an OpenAI API key in Dictation settings enables automatic language detection for future recordings.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Toggle("Record meetings automatically", isOn: Binding(get: { recorder.enabled }, set: { enabled in
                recorder.configure(enabled: enabled, locale: recorder.locale)
                if enabled { Task { await prepare() } }
            }))
            if recorder.enabled {
                if !usesOpenAI { localSpeechSettings }
                if !env.permissions.accessibilityGranted {
                    Button("Allow Accessibility…") { env.permissions.requestAccessibility() }
                }
                if env.permissions.microphone != .granted {
                    Button("Allow microphone…") {
                        if env.permissions.microphone == .notDetermined {
                            Task { await env.permissions.requestMicrophone() }
                        } else {
                            env.permissions.openMicrophoneSettings()
                        }
                    }
                }
                Text(recorder.displayStatus)
            }
        }
        .onAppear { env.dictation.refreshTranscriptionKeyStatus() }
        .task(id: usesOpenAI) {
            guard !usesOpenAI else { return }
            await env.speechAssets.refresh()
        }
    }

    @ViewBuilder
    private var localSpeechSettings: some View {
        Picker("Meeting language", selection: Binding(get: { recorder.locale }, set: {
            recorder.configure(enabled: true, locale: $0)
        })) {
            ForEach(DictationLocale.allCases, id: \.self) { Text($0.name).tag($0) }
        }
        .disabled(recorder.busy)
        SpeechModelRow(locale: recorder.locale, state: env.speechAssets.state(recorder.locale)) {
            Task {
                guard recorder.enabled, !usesOpenAI else { return }
                await env.speechAssets.install(recorder.locale)
            }
        }
    }

    private func prepare() async {
        if env.permissions.microphone == .notDetermined { await env.permissions.requestMicrophone() }
        guard recorder.enabled else { return }
        if !usesOpenAI {
            await env.speechAssets.refresh()
            if recorder.enabled, !usesOpenAI { await env.speechAssets.install(recorder.locale) }
        }
        recorder.check()
    }
}
