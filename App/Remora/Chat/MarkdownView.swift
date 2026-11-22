import AppKit
import ChatBar
import SwiftUI

/// Model Markdown as blocks (`MarkdownBlocks.parse`, safe while streaming), inline runs through
/// `MarkdownBlocks.inline` (only http, https and mailto links stay clickable, no remote images).
/// Hovering a block with links shows where they go, so link text can't hide its target.
struct MarkdownView: View {
    let text: String
    @Environment(\.chatFontSize) private var fontSize

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(MarkdownBlocks.parse(text).enumerated()), id: \.offset) { _, block in
                BlockView(block: block, fontSize: fontSize)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BlockView: View {
    let block: MarkdownBlock
    let fontSize: CGFloat

    var body: some View {
        switch block {
        case .heading(let level, let text):
            InlineText(text, font: .system(size: fontSize + CGFloat(max(0, 4 - level)) * 1.5, weight: .semibold))
                .padding(.top, 2)
        case .paragraph(let text):
            InlineText(text, font: .system(size: fontSize))
        case .bullet(let depth, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(depth == 0 ? "•" : "◦").font(.system(size: fontSize))
                InlineText(text, font: .system(size: fontSize))
            }
            .padding(.leading, CGFloat(depth) * 14)
        case .numbered(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number).").font(.system(size: fontSize).monospacedDigit())
                InlineText(text, font: .system(size: fontSize))
            }
        case .quote(let text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(.tertiary).frame(width: 3)
                InlineText(text, font: .system(size: fontSize)).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let language, let text, _):
            CodeBlock(language: language, text: text, fontSize: fontSize)
        case .rule:
            Divider().padding(.vertical, 2)
        }
    }
}

/// Inline Markdown; on hover, the hosts its links open.
private struct InlineText: View {
    let attributed: AttributedString
    let hosts: [String]
    let font: Font
    @State private var hovering = false

    init(_ text: String, font: Font) {
        attributed = MarkdownBlocks.inline(text)
        hosts = MarkdownBlocks.linkHosts(attributed)
        self.font = font
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(attributed)
                .font(font)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            if hovering, !hosts.isEmpty {
                Label("Opens " + hosts.joined(separator: ", "), systemImage: "arrow.up.forward.square")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .onHover { inside in if !hosts.isEmpty { hovering = inside } }
        .help(hosts.isEmpty ? "" : "Opens " + hosts.joined(separator: ", "))
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
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(size: fontSize - 1, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: true)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
