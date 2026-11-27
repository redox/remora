import Assistant
import ChatBar
import Dictation
import LLM
import Storage
import SwiftUI

extension EnvironmentValues {
    /// The chat's body size: 13 pt × the bar's text scale.
    @Entry var chatFontSize: CGFloat = 13
}

/// The expanded chat: header, message list, confirmation card and composer.
struct ChatView: View {
    @Bindable var model: ChatModel
    let bar: ChatBarController
    let pinned: Bool
    let textScale: Double
    /// The card's height (the confirmation card sizes its summary from it).
    let height: CGFloat
    let inChatWindow: Bool
    @FocusState private var composerFocused: Bool
    @State private var confirmClear = false
    @State private var messagePosition = ScrollPosition(idType: Int64?.self)
    @State private var atLatest = true
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var dictation: DictationController { model.dictation }
    private var fontSize: CGFloat { 13 * textScale }
    private var transcriptEdgeInset: CGFloat { 16 * textScale }
    private var hasMessages: Bool { !model.turns.isEmpty || model.sendingText != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            messages
            if let proposal = model.pendingConfirmation {
                Divider()
                ConfirmationCard(proposal: proposal, resolve: model.resolveConfirmation,
                                 summaryMaxHeight: ChatPresentation.cardSummaryMaxHeight(panelHeight: height,
                                                                                         fontSize: fontSize))
                    .padding(10)
            }
            if confirmClear {
                Divider()
                clearConfirmation
            }
            if let notice = model.cardNotice {
                Text(notice).font(.system(size: fontSize - 1)).foregroundStyle(.secondary).padding(.horizontal, 12)
                    .padding(.top, 6)
            }
            if let notice = model.notice {
                Text(notice).font(.system(size: fontSize - 1)).foregroundStyle(.secondary).padding(.horizontal, 12)
            }
            composer
        }
        .environment(\.chatFontSize, fontSize)
        .modifier(OverlaySurface(cornerRadius: inChatWindow ? 0 : 20))
        .onKeyPress(.escape) {
            guard inChatWindow, !model.isComposing else { return .ignored }
            if dictation.isDictatingChat {
                dictation.cancelChatRecording()
                return .handled
            }
            guard model.isStreaming else { return .ignored }
            model.stop()
            return .handled
        }
        .onChange(of: model.focusToken) { if model.takeFocusRequest() { composerFocused = true } }
        .onAppear {
            // A running turn already has its provisional UI. Reloading its stored user row
            // when reopening would show that message twice until the response finishes.
            if !model.isStreaming { model.reload() }
            // Opened with focus: the field exists only after this first layout.
            if model.takeFocusRequest() { Task { @MainActor in composerFocused = true } }
        }
    }

    /// Inline, not a sheet: a sheet would take key focus from the panel and collapse it.
    private var clearConfirmation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Clear chat history?").font(.system(size: fontSize, weight: .semibold))
            Text("This deletes the conversation and delivered messages. Reminders stay.")
                .font(.system(size: fontSize - 1))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { confirmClear = false }
                Button("Clear", role: .destructive) {
                    confirmClear = false
                    Task { await model.clearHistory() }
                }
            }
        }
        .padding(12)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            RemoraGlyph().frame(width: 20, height: 20)
                .foregroundStyle(RemoraBrand.accent(scheme)).accessibilityHidden(true)
            Text("Remora").font(.system(size: fontSize + 1, weight: .semibold))
            Spacer()
            HStack(spacing: 2) {
                if !inChatWindow {
                    Button { bar.openChatWindow() } label: {
                        Image(systemName: "macwindow.badge.plus")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(QuietButtonStyle())
                    .accessibilityLabel("Open in window")
                    .help("Open in a window visible in screenshots and screen sharing")
                    Button { bar.setPinned(!pinned) } label: {
                        Image(systemName: pinned ? "pin.fill" : "pin")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(QuietButtonStyle(selected: pinned))
                    .accessibilityLabel(pinned ? "Unpin chat" : "Pin chat")
                    .help(pinned ? "Unpin: close when you click elsewhere" : "Pin: keep the chat open")
                }
                Menu {
                    Button("Clear chat history…") { confirmClear = true }
                    Button("Settings…") { bar.actions.openSettings() }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .tint(Color.secondary)
                .fixedSize()
                .accessibilityLabel("Chat options")
                if !inChatWindow {
                    Button { bar.collapse() } label: {
                        Image(systemName: "chevron.up").frame(width: 28, height: 28)
                    }
                    .buttonStyle(QuietButtonStyle())
                    .accessibilityLabel("Collapse chat")
                    .help("Collapse")
                }
            }
        }
        .font(.system(size: fontSize - 1, weight: .medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Messages

    private var messages: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if !hasMessages { emptyState }
                ForEach(model.turns, id: \.id) { turn in
                    MessageView(turn: turn, model: model, bar: bar,
                                kind: turn.inboxID.flatMap { model.inboxKinds[$0] })
                        .onAppear {
                            if let inbox = turn.inboxID { model.markVisibleSeen([inbox]) }
                        }
                }
                if let sending = model.sendingText {
                    UserBubble(text: sending) { EmptyView() }
                    StreamingMessage(model: model)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 16)
            .padding(.vertical, transcriptEdgeInset)
        }
        .defaultScrollAnchor(hasMessages ? .bottom : .top, for: .initialOffset)
        .defaultScrollAnchor(.top, for: .alignment)
        // Follow layout changes from streamed text, status rows and the composer when at the end.
        .defaultScrollAnchor(hasMessages && atLatest ? .bottom : nil, for: .sizeChanges)
        .scrollPosition($messagePosition)
        .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, geometry in
            atLatest = Self.isNearLatest(geometry)
            // The lazy stack can revise its height after the first scroll to the end.
            if !atLatest && messagePosition.edge == .bottom {
                scrollToLatest()
            }
        }
        .onScrollPhaseChange { _, phase, context in
            // Manual scrolling clears the edge. Reattach after a gesture ends near the bottom.
            if phase == .idle, hasMessages, messagePosition.isPositionedByUser,
               Self.isNearLatest(context.geometry) {
                scrollToLatest()
            }
        }
        .onChange(of: model.isStreaming, initial: true) { _, isStreaming in
            if isStreaming { scrollToLatest() }
        }
        .onChange(of: hasMessages) { _, hasMessages in
            if !hasMessages { messagePosition.scrollTo(edge: .top) }
        }
        .onChange(of: model.scrollTarget, initial: true) { _, target in
            guard let target else { return }
            // The position's ID type matches the stored rows' ForEach key path.
            messagePosition.scrollTo(id: Optional(target), anchor: .top)
            model.scrollTarget = nil
        }
        .mask { transcriptEdgeMask }
        .overlay(alignment: .bottomTrailing) {
            if hasMessages && !atLatest && messagePosition.edge != .bottom {
                latestButton
                    .padding(.trailing, 16)
                    .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder private var transcriptEdgeMask: some View {
        if reduceTransparency || contrast == .increased {
            Color.black
        } else {
            GeometryReader { geometry in
                // Match the end padding so the first and last lines can scroll fully clear of the fade.
                let edge = min(0.25, transcriptEdgeInset / max(1, geometry.size.height))
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: edge),
                    .init(color: .black, location: 1 - edge),
                    .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }
        }
    }

    private var latestButton: some View {
        Button {
            scrollToLatest()
        } label: {
            Label("Latest", systemImage: "arrow.down")
                .font(.system(size: fontSize - 1, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        .buttonStyle(QuietButtonStyle())
        .modifier(OverlaySurface(cornerRadius: 10))
        .accessibilityLabel("Jump to latest message")
        .help("Jump to latest message")
    }

    private static func isNearLatest(_ geometry: ScrollGeometry) -> Bool {
        geometry.contentSize.height + geometry.contentInsets.bottom - geometry.visibleRect.maxY <= 20
    }

    private func scrollToLatest() {
        messagePosition.scrollTo(edge: .bottom)
    }

    private var emptyState: some View {
        ChatWelcome(prompt: ChatPresentation.emptyPrompt, starters: ChatPresentation.starters,
                    fontSize: fontSize, ask: model.ask)
            .disabled(model.isStreaming || dictation.isDictatingChat)
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.editingTurnID != nil, !model.isStreaming {
                HStack {
                    Label("Editing last message", systemImage: "pencil")
                    Spacer()
                    Button("Cancel") { model.cancelEditing() }.buttonStyle(.borderless)
                }
                .font(.system(size: fontSize - 1))
                .foregroundStyle(.secondary)
                if model.editingHasActions {
                    Text("Editing doesn’t undo actions already completed.")
                        .font(.system(size: fontSize - 1)).foregroundStyle(.secondary)
                }
            }
            if dictation.isDictatingChat {
                Label(recordingStatus, systemImage: "waveform")
                    .foregroundStyle(.secondary)
                if !dictation.chatPreview.isEmpty {
                    Text(dictation.chatPreview).lineLimit(3)
                }
            } else if let notice = dictation.chatNotice {
                HStack {
                    Text(notice.text)
                    if let action = notice.action {
                        Button("Open settings") { dictation.perform(action) }.buttonStyle(.link)
                    }
                }
            }
            composerInput
                .padding(.leading, 18)
                .padding(.trailing, 7)
                .padding(.vertical, 7)
                .background(OverlayComposerBackground(focused: composerFocused, cornerRadius: 25, raised: true))
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    private var recordingStatus: String {
        switch dictation.phase {
        case .starting: "Starting microphone…"
        case .listening: "Listening…"
        default: "Finishing dictation…"
        }
    }

    private var composerInput: some View {
        ChatComposerLayout {
            TextField("Ask Remora", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: fontSize + 2))
                .accessibilityLabel("Ask Remora")
                .help("Return to send · Shift Return for a new line")
                .lineLimit(1...6)
                .focused($composerFocused)
                .disabled(model.editingTurnID != nil && model.isStreaming)
                .onKeyPress(.return, phases: .down) { press in
                    // Enter sends (not while a turn runs), ⇧Enter adds a line at the caret. Return
                    // never answers a card, and sends nothing while one waits. While an input
                    // method composes, Return is its own.
                    switch ChatPresentation.returnKey(shift: press.modifiers.contains(.shift), composing: model.isComposing,
                                                      cardPending: model.pendingConfirmation != nil) {
                    case .passThrough: return .ignored
                    case .newline: model.insertNewline(); return .handled
                    case .swallow: return .handled
                    case .send: model.send(); return .handled
                    }
                }
            composerControls
        }
    }

    private var composerControls: some View {
        HStack(spacing: 3) {
            Button {
                if !dictation.isDictatingChat { bar.open(focusInput: true) }
                model.toggleDictation()
            } label: {
                composerIcon(dictation.isDictatingChat ? "stop.circle.fill" : "mic")
            }
            .buttonStyle(QuietButtonStyle(selected: dictation.isDictatingChat))
            .disabled(model.isStreaming || model.clearing || (dictation.isActive && !dictation.isDictatingChat)
                      || (dictation.isDictatingChat && dictation.phase == .finishing))
            .accessibilityLabel(dictation.isDictatingChat ? "Stop dictation" : "Dictate message")
            .help(dictation.isDictatingChat ? "Stop dictation (Esc to cancel)" :
                    (dictation.settings.enabled ? "Dictate message" : "Enable voice dictation in Settings"))
            if model.isStreaming {
                Button { model.stop() } label: { primaryComposerIcon("stop.fill", enabled: true) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop")
                    .help("Stop response (Esc)")
            } else {
                Button { model.send() } label: { primaryComposerIcon("arrow.up", enabled: model.canSend) }
                    .buttonStyle(.plain)
                    .disabled(!model.canSend)
                    .accessibilityLabel(model.editingTurnID == nil ? "Send" : "Save and resend")
                    .help(model.editingTurnID == nil ? "Send (Return)" : "Save and resend (Return)")
            }
        }
    }

    private func composerIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: fontSize + 2, weight: .medium))
            .frame(width: 36, height: 36)
    }

    private func primaryComposerIcon(_ symbol: String, enabled: Bool) -> some View {
        composerIcon(symbol)
            .foregroundStyle(enabled ? (scheme == .dark ? Color.black : .white) : .secondary)
            .background(enabled ? RemoraBrand.accent(scheme) : Color.primary.opacity(0.08), in: Circle())
            .contentShape(Circle())
    }
}

/// The user's text, right-aligned in a bubble.
struct UserBubble<Actions: View>: View {
    let text: String
    @ViewBuilder let actions: () -> Actions
    @Environment(\.chatFontSize) private var fontSize
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 4) {
                SelectableChatText(text, font: .systemFont(ofSize: fontSize))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(RemoraBrand.accent(scheme).opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                HStack(spacing: 6) {
                    CopyMessageButton(text: text)
                    actions()
                }
            }
        }
    }
}

/// The turn being answered: streamed Markdown, the running tool and this turn's receipts.
private struct StreamingMessage: View {
    let model: ChatModel
    @Environment(\.chatFontSize) private var fontSize

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.streamingText.isEmpty {
                MarkdownView(text: model.streamingText)
            }
            if let activity = model.activity {
                Label(activity, systemImage: "sparkle.magnifyingglass")
                    .font(.system(size: fontSize - 1))
                    .foregroundStyle(.secondary)
            } else if model.streamingText.isEmpty, model.pendingConfirmation == nil {
                ProgressView().controlSize(.small)
            }
            ForEach(model.liveReceipts) { ReceiptChipView(chip: $0, undo: model.undo) }
            CopyMessageButton(text: model.streamingText.isEmpty
                              ? model.liveReceipts.map { $0.receipt.summary }.joined(separator: "\n")
                              : model.streamingText)
        }
    }
}
