import SwiftUI

/// Stateless so the welcome layout can be previewed without loading memory or starting a model.
struct ChatWelcome: View {
    let prompt: String
    let starters: [String]
    let fontSize: CGFloat
    let ask: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("What’s on your mind?")
                    .font(.system(size: fontSize + 7, weight: .medium, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                Text(prompt)
                    .font(.system(size: fontSize))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                ForEach(starters, id: \.self) { question in
                    Button { ask(question) } label: {
                        HStack(spacing: 10) {
                            Text(question)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.left")
                                .font(.system(size: fontSize - 3))
                                .foregroundStyle(Color.secondary)
                                .accessibilityHidden(true)
                        }
                        .font(.system(size: fontSize))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                    }
                    .buttonStyle(QuietButtonStyle())
                }
            }
            .padding(.horizontal, -8)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
