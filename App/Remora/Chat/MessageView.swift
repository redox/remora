import AppKit
import Assistant
import LLM
import Storage
import SwiftUI

/// One stored turn: a user bubble, or the assistant's Markdown with its inbox label, receipts,
/// error line and details button.
struct MessageView: View {
    let turn: ChatTurn
    let model: ChatModel
    let bar: ChatBarController
    let kind: InboxKind?
    @Environment(\.chatFontSize) private var fontSize
    @State private var showDetails = false

    var body: some View {
        switch turn.role {
        case .user:
            VStack(alignment: .trailing, spacing: 4) {
                UserBubble(text: turn.text)
                if let id = turn.id, id == model.latestUserTurnID {
                    Button {
                        model.editLastMessage()
                        bar.open(focusInput: true)
                    } label: {
                        Label("Edit", systemImage: "pencil").padding(.vertical, 4)
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: fontSize - 1))
                    .foregroundStyle(.secondary)
                    .disabled(!model.canEditLastMessage)
                    .accessibilityLabel("Edit last message")
                    .help("Edit and resend your last message")
                }
            }
        case .assistant: assistant
        }
    }

    private var assistant: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let kind {
                Text(ChatPresentation.label(kind).uppercased())
                    .font(.system(size: fontSize - 3, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            if !turn.text.isEmpty { MarkdownView(text: turn.text) }
            receipts
            if let copy = ChatPresentation.errorCopy(turn) { errorLine(copy) }
            if !turn.llmCallIDs.isEmpty {
                Button { showDetails = true } label: {
                    Label("Details", systemImage: "info.circle").padding(.vertical, 4)
                }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .font(.system(size: fontSize - 1))
                    .help("Details")
                    .popover(isPresented: $showDetails, arrowEdge: .bottom) {
                        MessageDetailsView(model: model, turn: turn)
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// This session's receipts can be undone; older ones show their summary only.
    @ViewBuilder
    private var receipts: some View {
        if let id = turn.id, let chips = model.receipts[id] {
            ForEach(chips) { ReceiptChipView(chip: $0, undo: model.undo) }
        } else {
            ForEach(Array(ChatPresentation.storedReceipts(turn).enumerated()), id: \.offset) { _, summary in
                ReceiptLabel(summary: summary)
            }
        }
    }

    private func errorLine(_ copy: ChatPresentation.ErrorCopy) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if !copy.italic {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).accessibilityHidden(true)
                }
                Text(copy.text)
                    .italic(copy.italic)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch copy.action {
            case .manageUsage?:
                Button("Manage usage") { NSWorkspace.shared.open(SIWC.usageSettingsURL) }.buttonStyle(.link)
            case .openSettings?:
                Button("Open Settings") { bar.actions.openAccountSettings() }.buttonStyle(.link)
            case nil:
                EmptyView()
            }
        }
        .font(.system(size: fontSize - 1))
    }
}

/// "✓ <summary>" for a stored receipt.
struct ReceiptLabel: View {
    let summary: String
    @Environment(\.chatFontSize) private var fontSize

    var body: some View {
        Text("✓ " + summary)
            .font(.system(size: fontSize - 1))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A live receipt: "✓ <summary>" and **Undo**, then what the undo did.
struct ReceiptChipView: View {
    let chip: ChatModel.ReceiptChip
    let undo: (UUID) -> Void
    @Environment(\.chatFontSize) private var fontSize

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                ReceiptLabel(summary: chip.receipt.summary)
                switch chip.undo {
                case .available:
                    Button("Undo") { undo(chip.id) }.buttonStyle(.link)
                case .working:
                    ProgressView().controlSize(.mini)
                case .done:
                    if chip.receipt.undo != nil { Text("Undone").foregroundStyle(.secondary) }
                case .note:
                    EmptyView()
                }
            }
            if case .note(let message) = chip.undo {
                Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: fontSize - 1))
    }
}
