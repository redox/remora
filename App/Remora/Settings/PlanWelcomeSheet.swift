import AppKit
import LLM
import SwiftUI

struct PlanWelcomeSheet: View {
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("You're using your ChatGPT plan").font(.title2.bold())
            Text("Remora's AI requests use your ChatGPT plan. You can review and limit Remora's usage in ChatGPT settings.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Manage usage") { NSWorkspace.shared.open(SIWC.usageSettingsURL) }
                Spacer()
                Button("Got it", action: dismiss).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
