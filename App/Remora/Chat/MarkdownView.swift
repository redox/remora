import AppKit
import ChatBar
import Input
import SwiftUI

/// Consecutive prose blocks share a text view so a mouse selection can span paragraphs and lists.
/// Code keeps its own horizontal scroll area and copy button.
struct MarkdownView: View {
    let text: String
    @Environment(\.chatFontSize) private var fontSize

    var body: some View {
        let sections = ChatMarkdown(fontSize: fontSize).sections(text)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                switch section {
                case .prose(let prose):
                    SelectableChatText(prose)
                case .code(let language, let text):
                    CodeBlock(language: language, text: text, fontSize: fontSize)
                case .rule:
                    Divider().padding(.vertical, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Code in a monospaced box with a Copy button; long lines scroll sideways.
private struct CodeBlock: View {
    let language: String?
    let text: String
    let fontSize: CGFloat
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let language { Text(language).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    _ = SystemPasteboardAccess().write(text: text)
                    copied = true
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                SelectableChatText(text, font: .monospacedSystemFont(ofSize: fontSize - 1, weight: .regular))
                    .fixedSize(horizontal: true, vertical: true)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
