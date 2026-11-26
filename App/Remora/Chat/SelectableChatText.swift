import AppKit
import Input
import SwiftUI

/// A native first responder lets a drag start a selection on the first click in a hover-open panel.
struct SelectableChatText: NSViewRepresentable {
    let content: NSAttributedString

    init(_ content: NSAttributedString) {
        self.content = content
    }

    init(_ text: String, font: NSFont, color: NSColor = .labelColor) {
        content = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    }

    final class TextView: NSTextView {
        override var needsPanelToBecomeKey: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func copy(_ sender: Any?) {
            let selection = selectedRange()
            guard selection.length > 0 else { return }
            _ = SystemPasteboardAccess().write(text: (string as NSString).substring(with: selection))
        }
    }

    func makeNSView(context: Context) -> TextView {
        let view = TextView(frame: .zero)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        return view
    }

    func updateNSView(_ view: TextView, context: Context) {
        guard let storage = view.textStorage, !storage.isEqual(to: content) else { return }
        let selection = view.selectedRange()
        storage.setAttributedString(content)
        // Streaming replaces the attributed string even when the selected passage hasn't moved.
        if selection.length > 0, NSMaxRange(selection) <= content.length {
            view.setSelectedRange(selection)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TextView, context: Context) -> CGSize? {
        guard let layout = nsView.layoutManager, let container = nsView.textContainer else { return nil }
        let width = proposal.width ?? .greatestFiniteMagnitude
        container.containerSize = CGSize(width: max(1, width), height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return CGSize(width: min(width, ceil(used.width)), height: ceil(used.height))
    }
}

/// Copies the same source text while an answer streams and after the exchange is saved.
struct CopyMessageButton: View {
    let text: String
    @Environment(\.chatFontSize) private var fontSize
    @State private var copied = false

    var body: some View {
        if !text.isEmpty {
            Button {
                _ = SystemPasteboardAccess().write(text: text)
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy message", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .labelStyle(.iconOnly)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .font(.system(size: fontSize - 1))
            .help("Copy message")
            .task(id: copied) {
                guard copied else { return }
                try? await Task.sleep(for: .seconds(1.5))
                if !Task.isCancelled { copied = false }
            }
        }
    }
}
