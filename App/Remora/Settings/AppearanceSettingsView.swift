import ChatBar
import SwiftUI

struct AppearanceSettingsView: View {
    @Bindable var env: AppEnvironment
    /// A copy of the bar's settings for the controls; every change goes through `bar.update`.
    @State private var bar: BarSettings

    init(env: AppEnvironment) {
        self.env = env
        _bar = State(initialValue: env.bar.current)
    }

    var body: some View {
        Form {
            Section("Chat bar") {
                Picker("Position", selection: binding(\.position)) {
                    ForEach(BarPosition.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Open on hover", isOn: binding(\.openOnHover))
                    Text("When off, click the bar, use Open chat in the menu bar, or double-tap the rewrite key outside a text field.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Toggle("Auto-hide the bar", isOn: binding(\.autoHide))
                Toggle("Dim the bar when not in use", isOn: binding(\.dimWhenUnfocused))
                LabeledContent("Text size") {
                    HStack {
                        Slider(value: binding(\.textScale), in: 1.0...1.5, step: 0.1)
                        Text("\(Int((bar.textScale * 100).rounded())) %")
                            .monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                }
            }
            Section("Window badge") {
                Toggle("Show a capture badge on windows", isOn: $env.windowBadgeEnabled)
                Text("A small Remora icon at the top-right of the window you're using, showing whether it is captured. Click it for quick options. Hidden while you move or resize a window, in full screen, and while screen sharing or recording is detected (Zoom, Teams, Webex, FaceTime, Slack, Discord, Loom, CleanShot, macOS screen recording). Sharing from a browser tab isn't detected.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Re-read on appear: the chat (an action) or the bar itself may have changed them.
        .onAppear { bar = env.bar.current }
    }

    private func binding<T: Equatable>(_ key: WritableKeyPath<BarSettings, T>) -> Binding<T> {
        Binding(
            get: { bar[keyPath: key] },
            set: { value in
                env.bar.update { $0[keyPath: key] = value }
                bar = env.bar.current
            })
    }
}
