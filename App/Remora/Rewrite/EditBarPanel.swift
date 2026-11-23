import AppKit
import Dictation
import LLM
import Observation
import Rewrite
import SwiftUI

/// Edit mode's command bar: a non-activating panel that can become key (the user's app stays
/// active), anchored above the field. Enter submits, ⌘Z undoes the last round, Esc or a click
/// outside closes it. A spoken instruction shows in it while dictation listens. It never logs what
/// is typed or heard.
@MainActor
final class EditBarPanel {
    @MainActor @Observable
    final class Model {
        var instruction = ""
        /// Corrections to a transcript are still speech-derived and must never be stored as instructions.
        var draftIsSpoken = false
        var mode: EditVoiceRoute.Mode = .edit
        var replacesSelection = false
        var allowsEdit = true
        var canRemember = false
        var selectionOnly = false
        var noteDraft: SavedNoteDraft?
        var savedNoteID: UUID?
        var noteError: String?
        var fallbackActionTitle: String?
        var recordEnabled = false
        var triggerName: String?
        var finalizing = false
        var handsFree = false
        var recordingLocale: DictationLocale?
        var microphoneReady = false
        var isWorking = false
        var canUndo = false
        var notice: RewriteNotice?
        /// The backend that answered the last round; before the first, ChatGPT for a cloud tier and
        /// nil while an on-device tier may still fall back.
        var backend: LLMBackend? = .siwc
        /// No window title or text goes with the rounds.
        var fieldOnly = false
        /// The field's contents can only be used on-device.
        var onDeviceOnly = false
        /// Bumped to move keyboard focus to the text field.
        var focusToken = 0
        /// Dictation is listening for a spoken instruction: the text field shows what is heard.
        var listening = false

        var canSubmit: Bool {
            !isWorking && !listening && !finalizing && !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        var submission: EditVoiceRoute.Submission {
            mode.submission(hasFallback: fallbackActionTitle != nil)
        }

        var offersTranscriptInsertion: Bool { draftIsSpoken && submission == .compose && !listening && !finalizing }
        var promptOnly: Bool { submission == .compose && onDeviceOnly }

        var actionTitle: String {
            if submission == .compose { return "Draft and insert" }
            return fallbackActionTitle ?? mode.actionTitle(replacesSelection: replacesSelection)
        }

        var inputLabel: String {
            switch submission {
            case .edit: "Edit instruction"
            case .compose: draftIsSpoken ? "Dictated prompt" : "Drafting prompt"
            case .insertText: "Text to insert"
            }
        }

        var placeholder: String {
            if listening { return microphoneReady ? "Listening…" : "Opening microphone…" }
            if finalizing { return "Finishing transcript…" }
            switch submission {
            case .edit: return "What should change?"
            case .compose: return "What should I write?"
            case .insertText: return "Text to insert"
            }
        }
    }

    struct Actions {
        var submit: @MainActor (String, EditVoiceRoute.Submission) -> Void
        var record: @MainActor () -> Void
        var showsDictationLanguage: @MainActor () -> Bool
        var switchLanguage: @MainActor () -> Void
        /// Returns false when there is nothing to undo (⌘Z then goes to the text field).
        var undo: @MainActor () -> Bool
        var remember: @MainActor () -> Void
        var saveNote: @MainActor () -> Void
        var undoNote: @MainActor () -> Void
        var close: @MainActor () -> Void
        var noticeAction: @MainActor (RewriteNotice.Action) -> Void
    }

    private final class Panel: NSPanel {
        var onEscape: @MainActor () -> Void = {}
        var onUndo: @MainActor () -> Bool = { false }
        var onReturn: @MainActor () -> Void = {}
        var editsWritingDraft: @MainActor () -> Bool = { true }

        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }

        override func sendEvent(_ event: NSEvent) {
            if event.type == .keyDown {
                // An active input-method composition gets the key before the panel's shortcuts.
                let editor = firstResponder as? NSTextView
                if let editor, editor.hasMarkedText() {
                    super.sendEvent(event)
                    return
                }
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
                if event.keyCode == 53, flags.isEmpty {  // Esc: before the field editor turns it into completion
                    onEscape()
                    return
                }
                if editsWritingDraft(), event.keyCode == 36 || event.keyCode == 76 {
                    if flags.isEmpty {
                        onReturn()
                        return
                    }
                    if flags == .shift, let editor {
                        editor.insertNewlineIgnoringFieldEditor(nil)
                        return
                    }
                }
                if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "z", onUndo() { return }
            }
            super.sendEvent(event)
        }

        /// The app is not active, so the main menu's Edit items may not see these: route them to
        /// the text field directly.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
            if flags == .command, let key = event.charactersIgnoringModifiers?.lowercased() {
                let action: Selector? = switch key {
                case "x": #selector(NSText.cut(_:))
                case "c": #selector(NSText.copy(_:))
                case "v": #selector(NSText.paste(_:))
                case "a": #selector(NSText.selectAll(_:))
                default: nil
                }
                if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
            }
            return super.performKeyEquivalent(with: event)
        }
    }

    private static let height: CGFloat = 88

    let model: Model
    private let panel: Panel
    private let host: NSHostingView<EditBarView>
    private var monitors: [Any] = []
    private var actions: Actions?
    private var anchor: CGRect?

    init() {
        let model = Model()
        self.model = model
        host = NSHostingView(rootView: EditBarView(model: model, actions: nil))
        panel = Panel(contentRect: CGRect(x: 0, y: 0, width: 360, height: Self.height),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.contentView = host
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        panel.onReturn = { [weak self] in self?.submit() }
        panel.editsWritingDraft = { [weak model] in model?.noteDraft == nil && model?.savedNoteID == nil }
    }

    var isOpen: Bool { actions != nil }

    /// Opens the bar over the selection or field anchor in Cocoa screen coordinates.
    /// `focus: false` shows it without taking key focus (a spoken instruction while the rewrite key
    /// is still held: a key typed meanwhile must still reach the user's app); `focus()` takes it later.
    func open(over anchor: CGRect, mode: EditVoiceRoute.Mode, replacesSelection: Bool, allowsEdit: Bool,
              recordEnabled: Bool, triggerName: String?, actions: Actions, focus: Bool = true) {
        self.actions = actions
        model.instruction = ""
        model.draftIsSpoken = false
        model.mode = mode
        model.replacesSelection = replacesSelection
        model.allowsEdit = allowsEdit
        model.canRemember = false
        model.selectionOnly = false
        model.noteDraft = nil
        model.savedNoteID = nil
        model.noteError = nil
        model.fallbackActionTitle = nil
        model.recordEnabled = recordEnabled
        model.triggerName = triggerName
        model.finalizing = false
        model.handsFree = false
        model.recordingLocale = nil
        model.microphoneReady = false
        model.isWorking = false
        model.canUndo = false
        model.notice = nil
        model.backend = .siwc
        model.fieldOnly = false
        model.onDeviceOnly = false
        model.listening = false
        host.rootView = EditBarView(model: model, actions: actions, onSubmit: { [weak self] in self?.submit() },
                                    onHeightChange: { [weak self] height in self?.resize(to: height) })
        panel.onEscape = { actions.close() }
        panel.onUndo = { [weak model] in
            guard model?.noteDraft == nil, model?.savedNoteID == nil else { return false }
            return actions.undo()
        }
        self.anchor = anchor
        let frame = RewriteFlow.editBarFrame(field: anchor, height: Self.height,
                                             visible: ScreenPlacement.visibleFrame(for: anchor))
        panel.setFrame(frame, display: true)
        if focus {
            panel.makeKeyAndOrderFront(nil)
            model.focusToken += 1
        } else {
            panel.orderFrontRegardless()
        }
        installMonitors()
    }

    /// Measure the content, not the window: wrapped text can grow the panel without an
    /// animation or a focus change. The scroll view keeps it usable on very small screens.
    private func resize(to height: CGFloat) {
        guard isOpen, let anchor, height > 0 else { return }
        let frame = RewriteFlow.editBarFrame(field: anchor, height: ceil(height),
                                             visible: ScreenPlacement.visibleFrame(for: anchor))
        guard abs(panel.frame.height - frame.height) > 0.5 else { return }
        panel.setFrame(frame, display: panel.isVisible)
    }

    /// Takes key focus (the text field gets the keyboard).
    func focus() {
        guard isOpen else { return }
        panel.makeKeyAndOrderFront(nil)
        model.focusToken += 1
    }

    /// Shows a spoken instruction (partial or final) in the text field.
    func setInstruction(_ s: String) { model.instruction = s }

    /// The microphone glyph and the "Listening…" placeholder while dictation listens.
    func setListening(_ on: Bool) { model.listening = on }

    private func submit() {
        guard model.noteDraft == nil, model.savedNoteID == nil, model.canSubmit else { return }
        actions?.submit(model.instruction, model.submission)
    }

    func close() {
        removeMonitors()
        actions = nil
        model.instruction = ""
        model.noteDraft = nil
        model.savedNoteID = nil
        model.listening = false
        model.finalizing = false
        model.handsFree = false
        model.recordingLocale = nil
        anchor = nil
        panel.orderOut(nil)
        host.rootView = EditBarView(model: model, actions: nil)
    }

    /// Before a paste: give key focus back to the user's field.
    func hideForPaste() { panel.orderOut(nil) }

    /// After a paste: take key focus back (still open).
    func restoreAfterPaste() {
        guard isOpen else { return }
        panel.makeKeyAndOrderFront(nil)
        model.focusToken += 1
    }

    // MARK: -

    /// A mouse-down outside the bar closes it: in another app (global monitor) or in another of
    /// Remora's windows (local monitor).
    private func installMonitors() {
        removeMonitors()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.clickedOutside() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window !== self.panel { self.clickedOutside() }
            }
            return event
        }) { monitors.append(local) }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func clickedOutside() {
        guard panel.isVisible else { return }  // hidden for a paste: not the user's click on us
        actions?.close()
    }
}

struct EditBarView: View {
    @Bindable var model: EditBarPanel.Model
    let actions: EditBarPanel.Actions?
    var onSubmit: () -> Void = {}
    var onHeightChange: (CGFloat) -> Void = { _ in }
    @FocusState private var focused: Bool
    @FocusState private var focusedMode: EditVoiceRoute.Mode?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.layoutDirection) private var layoutDirection

    private var accent: Color { RemoraBrand.accent(scheme) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 7) {
                if let draft = model.noteDraft {
                    SavedNoteEditor(draft: draft, save: { actions?.saveNote() }, cancel: {
                        model.noteDraft = nil
                        model.focusToken += 1
                    })
                } else if model.savedNoteID != nil {
                    HStack {
                        Label("Saved to memory", systemImage: "checkmark.circle")
                        Spacer()
                        Button("Undo") { actions?.undoNote() }.disabled(model.isWorking)
                        Button("Done") { actions?.close() }
                    }
                } else if model.selectionOnly {
                    HStack {
                        rememberButton
                        Spacer()
                        closeButton
                    }
                } else {
                    controls
                    composer
                    footer
                }
                if let error = model.noteError, model.noteDraft == nil {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeightChange($0) }
        }
        .modifier(OverlaySurface(cornerRadius: 15))
        .onAppear { focused = true }
        .onChange(of: model.focusToken) { _, _ in focused = true }
    }

    private var controls: some View {
        HStack(spacing: 4) {
            HStack(spacing: 2) {
                modeButton("Insert", mode: .insert)
                if model.allowsEdit { modeButton("Edit", mode: .edit) }
            }
            .accessibilityRepresentation {
                Picker("Use text to", selection: $model.mode) {
                    Text("Insert").tag(EditVoiceRoute.Mode.insert)
                    if model.allowsEdit { Text("Edit").tag(EditVoiceRoute.Mode.edit) }
                }
                .pickerStyle(.segmented)
            }
            .disabled(model.isWorking || !model.allowsEdit)
            .help(model.triggerName.map { "Tap \($0) to switch modes" } ?? "Switch modes")

            if actions?.showsDictationLanguage() == true, let locale = model.recordingLocale {
                Button {
                    actions?.switchLanguage()
                } label: {
                    Text(locale.badge).padding(.horizontal, 8).frame(minHeight: 26)
                }
                .buttonStyle(QuietButtonStyle())
                .disabled(model.isWorking || model.finalizing || (model.listening && !model.microphoneReady))
                .help("Switch dictation language")
                .accessibilityLabel("Dictation language: \(locale.name). Switch language.")
            }
            if model.recordEnabled {
                let canStop = model.listening && model.handsFree
                Button {
                    actions?.record()
                } label: {
                    Label(canStop ? "Stop" : "Record", systemImage: canStop ? "stop.fill" : "mic")
                        .padding(.horizontal, 8)
                        .frame(minHeight: 26)
                }
                .buttonStyle(QuietButtonStyle())
                .disabled(model.isWorking || model.finalizing || (model.listening && !model.handsFree))
            }
            Spacer(minLength: 0)
            closeButton
        }
        .font(.callout)
    }

    private var closeButton: some View {
        Button { actions?.close() } label: {
            Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(QuietButtonStyle())
        .accessibilityLabel("Close editor")
        .help("Close editor (Esc)")
    }

    private var rememberButton: some View {
        Button("Remember this") { actions?.remember() }
            .buttonStyle(.link)
            .disabled(model.isWorking || model.listening || model.finalizing)
    }

    private func modeButton(_ title: String, mode: EditVoiceRoute.Mode) -> some View {
        Button {
            model.mode = mode
        } label: {
            Text(title).padding(.horizontal, 8).frame(minHeight: 26)
        }
        .buttonStyle(QuietButtonStyle(selected: model.mode == mode))
        .focused($focusedMode, equals: mode)
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            let leading = layoutDirection == .leftToRight ? KeyEquivalent.leftArrow : .rightArrow
            let next: EditVoiceRoute.Mode = press.key == leading ? .insert : .edit
            guard model.allowsEdit, !model.isWorking, next != mode else { return .ignored }
            model.mode = next
            focusedMode = next
            return .handled
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            if model.listening {
                Image(systemName: model.microphoneReady ? "mic.fill" : "mic")
                    .foregroundStyle(model.microphoneReady ? Color.red : Color.secondary)
                    .accessibilityLabel(model.placeholder)
            } else {
                RemoraGlyph().frame(width: 18, height: 18).foregroundStyle(accent).accessibilityHidden(true)
            }
            TextField(model.placeholder,
                      text: $model.instruction, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...6)
                .accessibilityLabel(model.inputLabel)
                .focused($focused)
                .disabled(model.isWorking || model.listening || model.finalizing)
            if model.isWorking {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(model.submission == .insertText ? "Preparing text" : "Writing")
            } else {
                Button(action: onSubmit) {
                    Text(model.actionTitle)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .frame(minHeight: 26)
                }
                .buttonStyle(QuietButtonStyle(selected: model.canSubmit))
                .disabled(!model.canSubmit)
                .help("\(model.actionTitle) (Return)")
            }
        }
        .padding(.leading, 10).padding(.trailing, 5).padding(.vertical, 5)
        .background(OverlayComposerBackground(focused: focused, cornerRadius: 10))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 5) {
            if model.canRemember || model.offersTranscriptInsertion {
                HStack {
                    if model.canRemember { rememberButton }
                    Spacer(minLength: 0)
                    if model.offersTranscriptInsertion {
                        Button("Insert transcript") { actions?.submit(model.instruction, .insertText) }
                            .buttonStyle(.link)
                            .disabled(!model.canSubmit)
                            .help("Insert your words using your dictation settings")
                    }
                }
            }
            if let notice = model.notice {
                WritingNoticeView(notice: notice) { actions?.noticeAction($0) }
                    .textSelection(.enabled)
                if model.canUndo {
                    undoButton.frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                HStack(alignment: .top, spacing: 6) {
                    if model.listening || model.finalizing {
                        Text("Transcribing on this Mac")
                    } else if model.promptOnly {
                        Text("Prompt only")
                            .help("Only the text you enter here can go to ChatGPT.")
                    } else if model.submission != .insertText {
                        Text(RewriteFlow.editBarFooter(backend: model.backend, fieldOnly: model.fieldOnly,
                                                       onDeviceOnly: model.onDeviceOnly))
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let trigger = model.triggerName, model.allowsEdit {
                        Text("Tap \(trigger) to switch modes")
                    }
                    Spacer(minLength: 0)
                    undoButton
                    if !model.listening, !model.finalizing,
                       model.promptOnly || (model.submission != .insertText
                           && model.backend != .onDevice && !model.onDeviceOnly) {
                        Button("Manage usage") { actions?.noticeAction(.manageUsage) }.buttonStyle(.link)
                    }
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var undoButton: some View {
        Button { _ = actions?.undo() } label: {
            Label("Undo", systemImage: "arrow.uturn.backward")
        }
        .buttonStyle(.borderless)
        .disabled(!model.canUndo || model.isWorking || model.listening || model.finalizing)
        .help("Undo the last edit (⌘Z)")
    }
}
