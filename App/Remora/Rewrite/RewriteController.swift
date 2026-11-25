import AppKit
import Capture
import Carbon.HIToolbox
import Dictation
import Input
import LLM
import Observation
import os
import Rewrite
import Storage

/// The rewrite key and Edit mode: reads the focused field, decides what the rewrite may use
/// (`RewriteFlow`), shows the caret indicator or the Edit bar, runs `RewriteEngine` and writes the
/// result back with `TextInserter`. The field is never touched until a full result is ready, and
/// only if it still holds what was read. The popover previews speech until the user submits it.
/// Never logs field text, prompts, instructions or results.
@MainActor @Observable
final class RewriteController {
    enum Phase: Equatable { case idle, working, editing, message(String) }

    private(set) var phase: Phase = .idle
    private(set) var shortcuts: ShortcutSettings
    /// Why the fallback chord is not registered; nil when it is (or is off).
    private(set) var chordError: String?
    /// Secure Event Input is on (a password field, Terminal's Secure Keyboard Entry): the key is ignored.
    private(set) var secureInputOn = false
    private(set) var isRunning = false

    /// A menu status line while the rewrite key cannot fire.
    var statusLine: String? {
        isRunning && shortcuts.rewriteKeyEnabled && secureInputOn ? "Rewrite key paused: secure input is on" : nil
    }

    // MARK: Dependencies

    @ObservationIgnored private let engine: RewriteEngine
    @ObservationIgnored private let account: AccountModel
    @ObservationIgnored private let db: AppDatabase
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let windows: FrontmostWindowReader
    @ObservationIgnored private let fields = FocusedFieldReader()
    @ObservationIgnored private let inserter = TextInserter(pasteboard: SystemPasteboardAccess(), keys: KeySynth(),
                                                            apps: AppActivation())
    @ObservationIgnored private let isPaused: @MainActor () -> Bool
    @ObservationIgnored private let openAccountSettings: @MainActor () -> Void
    @ObservationIgnored private let hotKeys = HotKeyCenter()
    @ObservationIgnored private var monitor: GlobalKeyMonitor?
    @ObservationIgnored private let indicator = CaretIndicatorPanel()
    @ObservationIgnored private let bar = EditBarPanel()
    @ObservationIgnored private let outcomes: OutcomeCheckScheduler
    @ObservationIgnored private var appObserver: (any NSObjectProtocol)?
    /// Spoken instructions, and the rewrite key stays quiet while dictation runs.
    @ObservationIgnored weak var dictation: DictationController?
    /// The rewrite key with nothing focused opens the chat bar instead of beeping.
    @ObservationIgnored var openChat: (@MainActor () -> Void)?

    // MARK: State

    /// Bumped by every start, cancel and close: a finishing task whose generation is stale only
    /// records what it did, it no longer touches the UI.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var work: Task<Void, Never>?
    /// False once the write has started: the write then runs to its end (cancel is ignored).
    @ObservationIgnored private var cancellable = false
    @ObservationIgnored private var hintGeneration = 0
    @ObservationIgnored private var edit: EditContext?
    @ObservationIgnored private var chordSuspended = false
    /// The outcome check of the Edit bar's last written round: only the last round is checked.
    @ObservationIgnored private var editCheck: (generation: Int, id: Int64)?

    @ObservationIgnored private var voiceHold = false
    @ObservationIgnored private var holdOpenedBar = false
    /// The draft that a cancelled or empty recording should restore.
    @ObservationIgnored private var draftBeforeRecording: String?

    private static let chordID: UInt32 = 1
    private static let escapeID: UInt32 = 2
    private static let escape = KeyChord(keyCode: 53, command: false, shift: false, option: false, control: false)
    private static let windowReadTimeout: Duration = .milliseconds(1500)
    private static let log = Logger(subsystem: "dev.remora", category: "rewrite")

    /// The Edit-mode conversation with one field.
    private struct EditContext {
        let generation: Int
        var field: FocusedField?
        let fallback: DictationTarget?
        let originalPID: pid_t?
        var noteSource: FrontmostWindowReader.ContextSample?
        var session: EditSession?
        var round: Task<Void, Never>?
        /// A round was written: the live window text read at open is stale from then on.
        var wrote = false
    }

    init(engine: RewriteEngine, account: AccountModel, db: AppDatabase, windows: FrontmostWindowReader,
         isPaused: @escaping @MainActor () -> Bool, openAccountSettings: @escaping @MainActor () -> Void) {
        self.engine = engine
        self.account = account
        self.db = db
        self.settings = SettingsStore(db)
        self.windows = windows
        self.isPaused = isPaused
        self.openAccountSettings = openAccountSettings
        let me = WeakRewriteController()
        outcomes = OutcomeCheckScheduler(engine: engine, mayRecord: { await me.value?.mayRecordOutcome($0) ?? false })
        shortcuts = Self.loadShortcuts(SettingsStore(db))
        me.value = self
    }

    private static func loadShortcuts(_ settings: SettingsStore) -> ShortcutSettings {
        do { return try settings.value(ShortcutSettings.self, forKey: ShortcutSettings.settingsKey) ?? ShortcutSettings() } catch {
            log.error("shortcut settings unreadable; using defaults")
            return ShortcutSettings()
        }
    }

    // MARK: - Lifecycle

    /// Called when Accessibility is granted. Idempotent.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        let monitor = monitor ?? GlobalKeyMonitor(settings: shortcuts, allowsDoubleTap: { [weak self] in
            self?.bar.isOpen != true
        }) { [weak self] in self?.trigger($0) }
        self.monitor = monitor
        monitor.update(shortcuts)
        monitor.start()
        registerChord()
        refreshSecureInput()
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { self?.appActivated(pid: pid) }
        }
    }

    /// Called when Accessibility is revoked: everything stops, any work is cancelled.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        endVoiceHold()
        monitor?.stop()
        hotKeys.unregister(id: Self.chordID)
        if let appObserver { NSWorkspace.shared.notificationCenter.removeObserver(appObserver) }
        appObserver = nil
        cancel()
        closeEditBar()
        // A write already under way still finishes, but shows nothing; its outcome is not checked.
        generation += 1
        outcomes.cancelAll()
        editCheck = nil
        indicator.hide()
        phase = .idle
    }

    func refreshSecureInput() {
        let on = IsSecureEventInputEnabled()
        if on != secureInputOn { secureInputOn = on }
    }

    func trigger(_ o: TapDetector.Output) {
        guard isRunning else { return }
        let state = EditVoiceRoute.State(
            dictationActive: dictation?.isRecording ?? false, voiceHold: voiceHold,
            canDictateInstruction: dictation?.isRunning ?? false, rewriteWorking: isWorking,
            barOpen: bar.isOpen, holdOpenedBar: holdOpenedBar)
        switch EditVoiceRoute.decide(o, state) {
        case .ignore: break
        case .rewrite: startRewrite()
        case .openPopover: openPopover(o == .holdReleased ? .edit : nil)
        case .switchMode:
            if !bar.model.isWorking, bar.model.allowsEdit { bar.model.mode = bar.model.mode.other }
        case .showHoldHint: showHoldHint()
        case .hideHoldHint: hideHoldHint()
        case .beginInstruction(let openBar): beginSpokenInstruction(openBar: openBar)
        case .finishInstruction: finishSpokenInstruction()
        case .cancelInstruction(let closeBar): cancelSpokenInstruction(closeBar: closeBar)
        }
    }

    /// A rewrite runs, the Edit bar is still opening, or an Edit round runs: dictation does not start.
    var isWorking: Bool {
        switch phase {
        case .working: true
        case .editing: edit == nil || edit?.round != nil
        case .idle, .message: false
        }
    }

    /// The writing popover is open.
    var isEditing: Bool { edit != nil }

    // MARK: - Settings

    func updateShortcuts(_ s: ShortcutSettings) {
        guard s != shortcuts else { return }
        // The monitor is rebuilt: the hold's release may never arrive, so drop a spoken instruction.
        endVoiceHold()
        shortcuts = s
        do { try settings.setValue(s, forKey: ShortcutSettings.settingsKey) } catch {
            Self.log.error("shortcut settings not saved")
        }
        monitor?.update(s)
        registerChord()
    }

    /// While the chord recorder listens, the current chord must reach it instead of firing.
    func setChordSuspended(_ suspended: Bool) {
        chordSuspended = suspended
        registerChord()
    }

    private func registerChord() {
        guard isRunning, shortcuts.chordEnabled, !chordSuspended else {
            hotKeys.unregister(id: Self.chordID)
            chordError = nil
            return
        }
        let chord = shortcuts.chord
        let registered = chord.isUsableHotKey
            && hotKeys.register(chord, id: Self.chordID, handler: { [weak self] in self?.startRewrite() })
        if !registered { hotKeys.unregister(id: Self.chordID) }
        chordError = RewriteFlow.chordError(chord, name: ChordName.string(chord), registered: registered)
    }

    // MARK: - Rewrite key

    /// A new gesture may start when nothing is working and the Edit bar is closed (a notice is dismissed).
    private var canStart: Bool {
        switch phase {
        case .idle, .message: true
        case .working, .editing: false
        }
    }

    private func startRewrite() {
        guard canStart else { return }
        hideHoldHint()
        indicator.hide()
        generation += 1
        let mine = generation
        phase = .working
        cancellable = true
        work = Task { [weak self] in await self?.runRewrite(mine) }
    }

    private func runRewrite(_ mine: Int) async {
        guard let field = await readField(openChatIfNothingFocused: true), isCurrent(mine) else { return finish(mine, nil) }
        let access: RewriteAccess
        switch await preflight(field, job: .rewrite) {
        case .refuse: return finish(mine, nil)
        case .notice(let notice): return finish(mine, notice, at: field)
        case .proceed(let a): access = a
        }
        guard isCurrent(mine) else { return finish(mine, nil) }
        let plan: RewritePlan
        do {
            guard let p = try RewriteFlow.plan(value: field.value, selection: field.selection,
                                               selectedText: field.selectedText, placeholder: field.placeholder) else {
                return finish(mine, .unreadable, at: field)
            }
            plan = p
        } catch {
            return finish(mine, RewriteFlow.notice(for: error), at: field)
        }

        indicator.showWorking(in: field) { [weak self] in self?.cancel() }
        hotKeys.register(Self.escape, id: Self.escapeID) { [weak self] in self?.cancel() }
        Sounds.play(.start, enabled: shortcuts.soundsEnabled)

        let request = await makeRequest(field: field, mode: plan.mode, fieldValue: plan.fieldValue, access: access)
        guard isCurrent(mine) else { return }
        let output: RewriteOutput
        do {
            output = try await engine.rewrite(request)
            try Task.checkCancellation()
        } catch {
            let notice = RewriteFlow.notice(for: error, onDeviceOnly: !request.cloudAllowed, mode: request.mode)
            return finish(mine, notice, at: field)
        }
        guard isCurrent(mine) else { return }
        // From here the write runs to its end; Esc and the indicator no longer cancel.
        cancellable = false
        hotKeys.unregister(id: Self.escapeID)

        let inserter = inserter
        let target = plan.target(for: output)
        let outcome = await Task.detached(priority: .userInitiated) {
            await inserter.insert(output.replacement, target: target, expectedValue: plan.expectedValue,
                                  expectedSelection: plan.expectedSelection, into: field.handle,
                                  preferPaste: field.isWebBacked || plan.prefersPaste)
        }.value
        if RewriteFlow.didInsert(outcome) {
            Sounds.play(.done, enabled: shortcuts.soundsEnabled)
            let original = (plan.fieldValue as NSString).substring(with: Self.clamp(output.range, plan.fieldValue))
            await record(output, request: request, original: original, instruction: nil, handle: field.handle)
        }
        finish(mine, RewriteFlow.notice(for: outcome), at: field)
    }

    /// Esc, or a click on the working indicator (a rewrite, or the Edit bar still opening).
    func cancel() {
        let opening = phase == .editing && edit == nil
        guard phase == .working || opening, cancellable else { return }
        if opening { endVoiceForBar() }
        work?.cancel()
        work = nil
        generation += 1
        hotKeys.unregister(id: Self.escapeID)
        indicator.hide()
        phase = .idle
    }

    /// Ends a rewrite: shows `notice` (with the error sound) or returns to idle.
    private func finish(_ mine: Int, _ notice: RewriteNotice?, at field: FocusedField? = nil) {
        guard isCurrent(mine) else { return }
        if phase == .editing, edit == nil { endVoiceForBar() }  // the bar could not open
        hotKeys.unregister(id: Self.escapeID)
        work = nil
        cancellable = false
        guard let notice else {
            indicator.hide()
            phase = .idle
            return
        }
        Sounds.play(.error, enabled: shortcuts.soundsEnabled)
        phase = .message(notice.text)
        indicator.showNotice(notice, at: field.flatMap { $0.caretRect ?? $0.frame }) { [weak self] action in
            self?.perform(action)
        }
        let shown = generation
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, self.generation == shown, case .message = self.phase else { return }
            self.phase = .idle
        }
    }

    private func isCurrent(_ mine: Int) -> Bool { mine == generation }

    // MARK: - Hold hint

    private func showHoldHint() {
        guard canStart else { return }
        hintGeneration += 1
        let mine = hintGeneration
        Task { [weak self] in
            guard let self else { return }
            let field = await fields.read()
            guard mine == hintGeneration, canStart, let field else { return }
            indicator.showHint(in: field)
        }
    }

    private func hideHoldHint() {
        hintGeneration += 1
        indicator.hideHint()
    }

    // MARK: - Edit mode

    private func openPopover(_ initialMode: EditVoiceRoute.Mode? = nil) {
        guard canStart else { return }
        hideHoldHint()
        indicator.hide()
        generation += 1
        let mine = generation
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let pointer = NSEvent.mouseLocation
        phase = .editing
        cancellable = true
        hotKeys.register(Self.escape, id: Self.escapeID) { [weak self] in self?.cancel() }
        work = Task { [weak self] in await self?.runOpenPopover(mine, initialMode: initialMode, pid: pid, pointer: pointer) }
    }

    private func runOpenPopover(_ mine: Int, initialMode: EditVoiceRoute.Mode?, pid: pid_t?, pointer: CGPoint) async {
        // The same browser window can switch tabs during the field read. Verify both sides.
        let verifySelection = initialMode == nil && !voiceHold && !isPaused()
        let before = verifySelection ? await windows.readContext() : nil
        let read = await fields.readField(includeWindowIdentity: before?.identity.window != nil,
                                         includeSelectionBounds: true)
        let context = await windows.readContext()
        guard isCurrent(mine), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              !IsSecureEventInputEnabled() else { return finish(mine, nil) }
        let field = read.field
        let rules = policy()
        let fallback: DictationTarget?
        var access: RewriteAccess?
        var session: EditSession?
        if let field {
            guard !field.isSecure else { return finish(mine, nil) }
            if case .proceed(let allowed) = gate(field, sample: context, rules: rules) {
                access = allowed
                if let value = field.value { session = try? EditSession(value: value, selection: field.selection) }
            }
            fallback = nil
        } else if case .refused(let reason) = read {
            fallback = DictationTarget.atInsertion(fieldRefusal: reason, secureInputOn: false)
        } else {
            fallback = .nowhere
        }
        guard fallback != .refuseSecure, CleanupRoute.forDictation(
            context: context?.context, contextPID: context?.identity.pid, fieldPID: field?.handle.pid,
            fieldBundleID: field?.bundleID, policy: rules, paused: isPaused()
        ) != .refuse else { return finish(mine, nil) }

        let dictationEnabled = dictation?.isRunning == true
        let permitsNotePreview = switch read {
        case .field, .refused(.noFocusedElement): true
        case .refused: false
        }
        let noteSource: FrontmostWindowReader.ContextSample?
        if permitsNotePreview, let context, context.identity.window != nil,
           before?.identity == context.identity, before?.context == context.context,
           !isPaused(), (try? RememberedNotes(db).allowsSelection(from: context.context)) == true {
            noteSource = context
        } else {
            noteSource = nil
        }
        guard session != nil || dictationEnabled || noteSource != nil else {
            return finish(mine, field == nil ? nil : .unreadable, at: field)
        }

        work = nil
        cancellable = false
        hotKeys.unregister(id: Self.escapeID)
        edit = EditContext(generation: mine, field: field, fallback: fallback, originalPID: pid,
                           noteSource: noteSource, session: session)
        let focus = EditVoiceRoute.barTakesFocus(barOpen: true, voiceHold: voiceHold, holdOpenedBar: holdOpenedBar)
        let replacesSelection = (field?.selection?.length ?? 0) > 0
        let mode = initialMode ?? EditVoiceRoute.Mode.preferred(replacesSelection: replacesSelection)
        let placement = field.flatMap { $0.handle.pid == pid ? $0 : nil }
        let anchor = RewriteFlow.editBarAnchor(
            field: placement?.frame.map(ScreenPlacement.cocoa(fromAX:)),
            selection: placement?.selectionBounds.map(ScreenPlacement.cocoa(fromAX:)),
            caret: placement?.caretRect.map(ScreenPlacement.cocoa(fromAX:)),
            preferNearbyPointer: replacesSelection || placement?.selectedText?.isEmpty == false || placement?.role == "AXWebArea",
            pointer: pointer, context: context?.identity.pid == pid ? context?.context : nil)
        bar.open(over: anchor, mode: session == nil ? .insert : mode,
                 replacesSelection: replacesSelection, allowsEdit: session != nil,
                 recordEnabled: dictationEnabled, triggerName: shortcuts.rewriteKeyEnabled ? shortcuts.trigger.title : nil,
                 actions: EditBarPanel.Actions(
                    submit: { [weak self] in self?.submitDraft($0, submission: $1) },
                    record: { [weak self] in self?.toggleRecording() },
                    showsDictationLanguage: { [weak dictation] in dictation?.hasTranscriptionKey == false },
                    switchLanguage: { [weak self] in self?.switchRecordingLanguage() },
                    undo: { [weak self] in self?.undoRound() ?? false },
                    remember: { [weak self] in self?.previewNote() },
                    saveNote: { [weak self] in self?.saveNote() },
                    undoNote: { [weak self] in self?.undoSavedNote() },
                    close: { [weak self] in self?.closeEditBar() },
                    noticeAction: { [weak self] in self?.perform($0) }),
                 focus: focus)
        bar.model.canRemember = noteSource != nil
        bar.model.selectionOnly = session == nil && !dictationEnabled
        if dictationEnabled { bar.model.recordingLocale = dictation?.preferredLocale }
        if let fallback { bar.model.fallbackActionTitle = fallback == .nowhere ? "Copy text" : "Insert text" }
        bar.model.onDeviceOnly = access?.cloudAllowed == false
        bar.model.backend = account.routing.tier(for: .editMode) == .onDevice ? nil : .siwc
        bar.model.fieldOnly = access?.windowContextAllowed == false
        if voiceHold { startRecording(handsFree: false) }
        if !focus {
            // The panel cannot consume Esc while it is displayed without taking keyboard focus.
            hotKeys.register(Self.escape, id: Self.escapeID) { [weak self] in self?.closeEditBar() }
        }
    }

    private func previewNote() {
        guard let ctx = edit, ctx.round == nil, let source = ctx.noteSource,
              !bar.model.listening, !bar.model.finalizing
        else { return }
        let selection = ctx.field?.verifiedExcerpt(in: source) ?? ""
        guard selection.utf8.count <= RememberedNotes.maximumTextBytes else {
            bar.model.noteError = "Select a shorter excerpt to save."
            return
        }
        bar.model.noteError = nil
        bar.model.isWorking = true
        edit?.round = Task { [weak self] in
            guard let self else { return }
            let generation = try? DataGeneration.current(db)
            let allowed = await noteSourceIsCurrent(source)
            guard edit?.generation == ctx.generation else { return }
            if allowed, let generation,
               (try? RememberedNotes(db).allowsSelection(from: source.context)) == true {
                bar.model.noteDraft = SavedNoteDraft(text: selection, generation: generation)
            } else {
                bar.model.noteError = "This selection can no longer be saved."
            }
            edit?.round = nil
            bar.model.isWorking = false
        }
    }

    private func saveNote() {
        guard let ctx = edit, ctx.round == nil, let source = ctx.noteSource,
              let draft = bar.model.noteDraft, !draft.saving else { return }
        draft.saving = true
        draft.error = nil
        let text = draft.text, annotation = draft.annotation, generation = draft.generation
        let notes = RememberedNotes(db)
        edit?.round = Task { [weak self] in
            guard let self else { return }
            do {
                guard await noteSourceIsCurrent(source), edit?.generation == ctx.generation else {
                    throw RememberedNotes.Refusal.sourceUnavailable
                }
                let note = try await Task.detached {
                    try notes.save(text, annotation: annotation, from: source.context, generation: generation)
                }.value
                guard edit?.generation == ctx.generation else { return }
                bar.model.noteDraft = nil
                bar.model.savedNoteID = note.id
            } catch {
                draft.showSaveError(error)
            }
            guard edit?.generation == ctx.generation else { return }
            draft.saving = false
            edit?.round = nil
        }
    }

    private func noteSourceIsCurrent(_ source: FrontmostWindowReader.ContextSample) async -> Bool {
        guard let current = await windows.readContext(), current.identity == source.identity,
              current.context == source.context else { return false }
        return !Task.isCancelled && !isPaused() && !IsSecureEventInputEnabled()
    }

    private func undoSavedNote() {
        guard let id = bar.model.savedNoteID, !bar.model.isWorking, let ctx = edit else { return }
        bar.model.isWorking = true
        let store = SavedNoteStore(db)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.detached { try store.delete(id) }.value
                if edit?.generation == ctx.generation { closeEditBar() }
            } catch {
                guard edit?.generation == ctx.generation else { return }
                bar.model.isWorking = false
                bar.model.noteError = "Could not undo the save."
            }
        }
    }

    private func submitDraft(_ draft: String, submission: EditVoiceRoute.Submission) {
        guard bar.model.canSubmit, let ctx = edit, ctx.round == nil, !IsSecureEventInputEnabled() else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        switch submission {
        case .edit:
            dictation?.cancelSession()
            submitRound(text, spoken: bar.model.draftIsSpoken)
        case .compose:
            // Keep the reviewed transcript available for direct insertion if drafting fails.
            bar.model.isWorking = true
            bar.model.notice = nil
            edit?.round = Task { [weak self] in await self?.composeDraft(text, context: ctx) }
        case .insertText:
            bar.model.isWorking = true
            bar.model.notice = nil
            edit?.round = Task { [weak self] in await self?.insertDraft(text, context: ctx) }
        }
    }

    private func composeDraft(_ instruction: String, context: EditContext) async {
        let mine = context.generation
        guard let field = context.field, let expected = field.value else {
            return endRound(mine, notice: .unreadable)
        }
        let handle = field.handle
        let unchanged = await Task.detached(priority: .userInitiated) {
            handle.value() == expected
        }.value
        guard edit?.generation == mine, !Task.isCancelled else { return }
        guard unchanged else { return endRound(mine, notice: .fieldChanged) }
        guard let request = await preparePopoverRequest(field: field, value: expected, context: context) else { return }

        let output: RewriteOutput
        do {
            output = try await engine.compose(instruction: instruction, selection: field.selection, request: request)
            try Task.checkCancellation()
        } catch {
            return endRound(mine, notice: RewriteFlow.notice(for: error))
        }
        let currentGate = await gate(field)
        guard edit?.generation == mine, !Task.isCancelled else { return }
        guard !IsSecureEventInputEnabled(), case .proceed = currentGate else {
            return endRound(mine, notice: nil)
        }

        let outcome = await write(output.replacement, target: .caret, expected: expected,
                                  expectedSelection: field.selection, field, generation: mine)
        guard edit?.generation == mine else { return }
        if let notice = RewriteFlow.notice(for: outcome) { return endRound(mine, notice: notice) }
        if RewriteFlow.didInsert(outcome) { Sounds.play(.done, enabled: shortcuts.soundsEnabled) }
        closeEditBar()
    }

    private func insertDraft(_ text: String, context: EditContext) async {
        let mine = context.generation
        if let field = context.field {
            // Reject a changed value before processing the recording. The paste path checks the
            // original caret or selection after the editor gives up keyboard focus.
            let handle = field.handle
            let unchanged = await Task.detached(priority: .userInitiated) {
                handle.value() == field.value
            }.value
            guard edit?.generation == mine, !Task.isCancelled else { return }
            guard unchanged else { return endRound(mine, notice: RewriteFlow.notice(for: .fieldChanged)) }
        }
        let prepared: DictationController.InsertionText
        if let dictation {
            guard let result = await dictation.prepareInsertion(text, field: context.field) else {
                return endRound(mine, notice: bar.model.notice)
            }
            prepared = result
        } else {
            prepared = .init(text: text, locale: .en, notice: nil)
        }
        let sample = await windows.readContext()
        guard edit?.generation == mine, !Task.isCancelled else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == context.originalPID,
              !IsSecureEventInputEnabled(), !BuiltInSkipList.isPasswordVault(host: sample?.context.domain) else {
            return endRound(mine, notice: nil)
        }

        if let field = context.field {
            let preceding = DictationSpacing.preceding(value: field.value, selection: field.selection)
            let value = DictationSpacing.prepare(prepared.text, preceding: preceding, locale: prepared.locale)
            let outcome = await write(value, target: .caret, expected: field.value,
                                      expectedSelection: field.selection, field, generation: mine)
            guard edit?.generation == mine else { return }
            switch outcome {
            case .ax, .paste, .noChange: break
            case .fieldChanged, .notFocused:
                return endRound(mine, notice: RewriteFlow.notice(for: outcome))
            case .failed:
                return copyDraft(prepared.text, at: field)
            }
        } else if context.fallback == .frontmostPaste, let pid = context.originalPID {
            bar.hideForPaste()
            try? await Task.sleep(for: .milliseconds(80))
            guard edit?.generation == mine, !Task.isCancelled else { return }
            let read = await fields.readField()
            guard edit?.generation == mine, !Task.isCancelled else { return }
            if IsSecureEventInputEnabled() {
                bar.restoreAfterPaste()
                return endRound(mine, notice: nil)
            }
            if case .refused(let reason) = read {
                switch DictationTarget.atInsertion(fieldRefusal: reason, secureInputOn: false) {
                case .refuseSecure:
                    bar.restoreAfterPaste()
                    return endRound(mine, notice: nil)
                case .nowhere: return copyDraft(prepared.text)
                case .field, .frontmostPaste: break
                }
            }
            let inserter = inserter
            let outcome = await Task.detached(priority: .userInitiated) {
                await inserter.pasteIntoFrontmost(prepared.text, expectedPID: pid)
            }.value
            guard edit?.generation == mine else { return }
            if !RewriteFlow.didInsert(outcome) { return copyDraft(prepared.text) }
        } else {
            return copyDraft(prepared.text)
        }
        finishDictationInsertion(prepared.notice, at: context.field)
    }

    private func copyDraft(_ text: String, at field: FocusedField? = nil) {
        _ = SystemPasteboardAccess().write(text: text)
        finishDictationInsertion(.copiedInstead, at: field)
    }

    private func finishDictationInsertion(_ notice: DictationNotice?, at field: FocusedField?) {
        closeEditBar()
        if let notice {
            indicator.showNotice(notice.writingNotice, at: field.flatMap { $0.caretRect ?? $0.frame }) { [weak self] in
                self?.perform($0)
            }
        }
    }

    /// `spoken`: the instruction is a transcript, so it is never stored (`recordInserted(spoken:)`).
    /// False when no round started (one is running, or the instruction is empty).
    @discardableResult
    private func submitRound(_ instruction: String, spoken: Bool) -> Bool {
        guard var ctx = edit, ctx.session != nil, ctx.round == nil,
              !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        bar.model.isWorking = true
        bar.model.notice = nil
        let mine = ctx.generation
        ctx.round = Task { [weak self] in await self?.runRound(instruction, spoken: spoken, mine) }
        edit = ctx
        return true
    }

    private func runRound(_ instruction: String, spoken: Bool, _ mine: Int) async {
        guard let ctx = edit, ctx.generation == mine, let field = ctx.field, let session = ctx.session else { return }
        let handle = field.handle
        let (current, selection) = await Task.detached(priority: .userInitiated) {
            (handle.value(), handle.selectedRange())
        }.value
        guard let current else { return endRound(mine, notice: .unreadable) }
        let round: EditRound
        do { round = try RewriteFlow.editRound(session, currentValue: current, selection: selection) } catch {
            return endRound(mine, notice: RewriteFlow.notice(for: error))
        }
        guard let request = await preparePopoverRequest(field: field, value: current, context: ctx) else { return }
        let output: RewriteOutput
        do {
            output = try await engine.edit(instruction: instruction, text: round.text, fullRange: round.range, request: request)
            try Task.checkCancellation()
        } catch {
            return endRound(mine, notice: RewriteFlow.notice(for: error, onDeviceOnly: !request.cloudAllowed))
        }
        guard edit?.generation == mine else { return }
        guard !IsSecureEventInputEnabled() else { return endRound(mine, notice: nil) }
        if let backend = output.backend { bar.model.backend = backend }
        let (next, newValue) = round.applying(output.replacement, to: current)
        let outcome = await write(newValue, expected: current, field, generation: mine)
        if RewriteFlow.didInsert(outcome) {
            Sounds.play(.done, enabled: shortcuts.soundsEnabled)
            if let id = await record(output, request: request, original: round.text, instruction: instruction,
                                     spoken: spoken, handle: handle) {
                // Only the last round is checked: its result supersedes the earlier ones.
                if let previous = editCheck, previous.generation == mine { outcomes.cancel(id: previous.id) }
                editCheck = (mine, id)
            }
        }
        guard edit?.generation == mine else { return }
        switch outcome {
        case .ax, .paste:
            edit?.session = next
            edit?.wrote = true
            await refreshInsertionTarget(field, generation: mine)
        case .noChange: edit?.session = round.session
        case .fieldChanged, .notFocused, .failed: break
        }
        guard edit?.generation == mine else { return }
        if RewriteFlow.notice(for: outcome) == nil {
            bar.model.instruction = ""
            bar.model.draftIsSpoken = false
        }
        endRound(mine, notice: RewriteFlow.notice(for: outcome))
    }

    private func preparePopoverRequest(field: FocusedField, value: String, context: EditContext) async -> RewriteRequest? {
        let mine = context.generation
        let access: RewriteAccess
        switch await preflight(field, job: .editMode) {
        case .refuse:
            endRound(mine, notice: nil)
            return nil
        case .notice(let notice):
            endRound(mine, notice: notice)
            return nil
        case .proceed(let allowed): access = allowed
        }
        guard edit?.generation == mine, !Task.isCancelled else { return nil }
        guard !IsSecureEventInputEnabled() else {
            endRound(mine, notice: nil)
            return nil
        }
        var base = await makeRequest(field: field, mode: .full, fieldValue: value, access: access,
                                     includeLiveText: !context.wrote)
        let handle = field.handle
        let stillFocused = await Task.detached(priority: .userInitiated) {
            handle.pid == ProcessInfo.processInfo.processIdentifier || handle.isFocusedInApp()
        }.value
        let latest = await gate(field)
        guard edit?.generation == mine, !Task.isCancelled else { return nil }
        guard stillFocused, !IsSecureEventInputEnabled(), case .proceed(let allowed) = latest else {
            endRound(mine, notice: nil)
            return nil
        }
        if !allowed.windowContextAllowed {
            base.windowTitle = nil
            base.liveWindowText = nil
        }
        base.cloudAllowed = base.cloudAllowed && allowed.cloudAllowed
        base.memoryAllowed = base.memoryAllowed && allowed.memoryAllowed
        base.logAllowed = base.logAllowed && allowed.logAllowed
        let request = RewriteFlow.roundRequest(base, fieldValue: value, paused: isPaused(), wroteBefore: context.wrote)
        bar.model.onDeviceOnly = !request.cloudAllowed
        bar.model.fieldOnly = RewriteFlow.isFieldOnly(request)
        return request
    }

    /// ⌘Z in the bar: writes the value before the last round back. False when there is nothing to undo.
    private func undoRound() -> Bool {
        guard var ctx = edit, let session = ctx.session, session.canUndo, let field = ctx.field else { return false }
        guard !bar.model.listening, !bar.model.finalizing else { return true }
        guard ctx.round == nil else { return true }  // swallow it while a round runs
        bar.model.isWorking = true
        bar.model.notice = nil
        let mine = ctx.generation
        ctx.round = Task { [weak self] in
            guard let self, edit?.generation == mine else { return }
            let handle = field.handle
            let (current, selection) = await Task.detached(priority: .userInitiated) {
                (handle.value(), handle.selectedRange())
            }.value
            guard let current, let undo = RewriteFlow.undoRound(session, currentValue: current, selection: selection) else {
                NSSound.beep()
                return endRound(mine, notice: nil)
            }
            let outcome = await write(undo.value, expected: current, field, generation: mine)
            guard edit?.generation == mine else { return }
            switch outcome {
            case .ax, .paste:
                edit?.session = undo.session
                await refreshInsertionTarget(field, generation: mine)
            case .noChange: edit?.session = undo.session
            case .fieldChanged, .notFocused, .failed: break
            }
            endRound(mine, notice: RewriteFlow.notice(for: outcome))
        }
        edit = ctx
        return true
    }

    /// Insert can follow Edit in the same popover; keep its target and label in sync with the
    /// value and selection the host app actually kept after a successful edit or undo.
    private func refreshInsertionTarget(_ field: FocusedField, generation: Int) async {
        let handle = field.handle
        let (value, selection) = await Task.detached(priority: .userInitiated) {
            (handle.value(), handle.selectedRange())
        }.value
        guard edit?.generation == generation else { return }
        var updated = field
        updated.value = value
        updated.selection = selection
        edit?.field = updated
        bar.model.replacesSelection = (selection?.length ?? 0) > 0
    }

    /// Writes the result into the original field. If pasting, the bar steps aside to let the
    /// field take key focus again.
    private func write(_ value: String, target: InsertionTarget = .whole, expected: String?,
                       expectedSelection: NSRange? = nil, _ field: FocusedField, generation: Int) async -> InsertionOutcome {
        let inserter = inserter
        let preferPaste = field.isWebBacked
            || (target == .caret && expected?.contains(RewriteFlow.objectReplacement) == true)
        return await Task.detached(priority: .userInitiated) {
            await inserter.insert(value, target: target, expectedValue: expected,
                                  expectedSelection: expectedSelection, into: field.handle,
                                  preferPaste: preferPaste,
                                  beforePaste: {
                                      await MainActor.run { [weak self] in
                                          if self?.edit?.generation == generation { self?.bar.hideForPaste() }
                                      }
                                      // Let the app's window take key focus back before the focus check.
                                      try? await Task.sleep(for: .milliseconds(80))
                                  },
                                  afterPaste: { [weak self] in
                                      await MainActor.run {
                                          if self?.edit?.generation == generation { self?.bar.restoreAfterPaste() }
                                      }
                                  })
        }.value
    }

    private func endRound(_ mine: Int, notice: RewriteNotice?) {
        guard edit?.generation == mine else { return }
        edit?.round = nil
        bar.model.isWorking = false
        bar.model.canUndo = edit?.session?.canUndo ?? false
        bar.model.notice = notice
        if edit?.wrote == true {
            edit?.noteSource = nil
            bar.model.canRemember = false
        }
        bar.model.focusToken += 1  // the field was disabled while working: give it focus back
        if notice != nil { Sounds.play(.error, enabled: shortcuts.soundsEnabled) }
    }

    /// Esc, a click outside, another app activated, or Accessibility revoked. Cancels a round in
    /// flight (a write already started still finishes) and any instruction dictation is hearing.
    func closeEditBar() {
        edit?.round?.cancel()
        let wasEditing = edit != nil || phase == .editing
        if wasEditing {
            hotKeys.unregister(id: Self.escapeID)
            indicator.hide()
        }
        edit = nil
        bar.close()
        endVoiceForBar()
        guard wasEditing else { return }
        generation += 1  // also stops a bar that is still opening
        work?.cancel()
        work = nil
        if phase == .editing { phase = .idle }
    }

    private func appActivated(pid: pid_t?) {
        guard let ctx = edit, let pid, pid != ctx.originalPID,
              pid != ProcessInfo.processInfo.processIdentifier else { return }
        closeEditBar()
    }

    // MARK: - Recording

    private func beginSpokenInstruction(openBar: Bool) {
        hideHoldHint()
        voiceHold = true
        holdOpenedBar = openBar
        if openBar {
            openPopover(.insert)
        } else {
            startRecording(handsFree: false)
        }
    }

    private func finishSpokenInstruction() {
        voiceHold = false
        holdOpenedBar = false
        if bar.isOpen { hotKeys.unregister(id: Self.escapeID) }
        if dictation?.isRecording == true {
            finalizeTranscript()
            dictation?.finishRecording()
        } else {
            bar.focus()
        }
    }

    private func cancelSpokenInstruction(closeBar: Bool) {
        voiceHold = false
        holdOpenedBar = false
        if closeBar {
            closeEditBar()
        } else {
            dictation?.cancelSession()
            bar.focus()
        }
    }

    private func endVoiceHold() {
        if voiceHold {
            cancelSpokenInstruction(closeBar: holdOpenedBar)
        } else if dictation?.isRecording == true {
            dictation?.cancelSession()
        }
    }

    private func toggleRecording() {
        if bar.model.handsFree, dictation?.isRecording == true {
            finalizeTranscript()
            dictation?.finishRecording()
        } else {
            startRecording(handsFree: true)
        }
    }

    private func startRecording(handsFree: Bool) {
        guard bar.model.noteDraft == nil, bar.model.savedNoteID == nil, !bar.model.selectionOnly,
              let edit, edit.round == nil,
              dictation?.beginRecording(field: edit.field, locale: bar.model.recordingLocale) == true else { return }
        draftBeforeRecording = bar.model.instruction
        bar.model.notice = nil
        bar.model.instruction = ""
        bar.model.handsFree = handsFree
        bar.model.microphoneReady = false
        bar.setListening(true)
    }

    private func switchRecordingLanguage() {
        if bar.model.listening {
            dictation?.switchSessionLocale()
        } else {
            bar.model.recordingLocale = bar.model.recordingLocale?.other
        }
    }

    func recordingIsReady(_ locale: DictationLocale) {
        bar.model.recordingLocale = locale
        bar.model.microphoneReady = true
    }

    func showDictationNotice(_ notice: DictationNotice) {
        guard bar.isOpen else { return }
        bar.model.notice = notice.writingNotice
    }

    func showTranscript(_ partial: String) {
        guard bar.model.listening else { return }
        bar.setInstruction(partial)
    }

    func finalizeTranscript() {
        guard bar.model.listening else { return }
        bar.setListening(false)
        bar.model.finalizing = true
        if !voiceHold { bar.focus() }
    }

    func showFinalTranscript(_ text: String) {
        guard bar.isOpen else { return }
        draftBeforeRecording = nil
        bar.model.draftIsSpoken = true
        bar.setInstruction(text)
        finishRecordingUI()
    }

    func restoreDraftAfterRecording() {
        guard let draft = draftBeforeRecording else { return }
        draftBeforeRecording = nil
        bar.setInstruction(draft)
        finishRecordingUI()
    }

    private func finishRecordingUI() {
        bar.setListening(false)
        bar.model.finalizing = false
        bar.model.handsFree = false
        bar.model.microphoneReady = false
        if !voiceHold { bar.focus() }
    }

    private func endVoiceForBar() {
        voiceHold = false
        holdOpenedBar = false
        draftBeforeRecording = nil
        dictation?.cancelSession()
    }

    // MARK: - Shared steps

    /// The focused field, or nil after a beep (nothing focused, a secure field, a password manager,
    /// Remora itself, or an app not responding). A refused field's text is never read. With
    /// `openChatIfNothingFocused` (the rewrite key), nothing focused opens the chat bar instead of
    /// beeping; every other refusal still beeps.
    private func readField(openChatIfNothingFocused: Bool = false) async -> FocusedField? {
        let read = await fields.readField()
        if openChatIfNothingFocused, case .refused(.noFocusedElement) = read, let openChat {
            openChat()
            return nil
        }
        guard case .field(let field) = read, !field.isSecure else {
            NSSound.beep()
            return nil
        }
        return field
    }

    private func signInNotice(for job: JobType) async -> RewriteNotice? {
        await account.refreshState()
        return RewriteFlow.signInNotice(state: account.state, tier: account.routing.tier(for: job))
    }

    /// The privacy gate, then (only for a field it lets through to the cloud) the sign-in check. A
    /// refused field (password manager, web vault, unverifiable browser page) beeps and shows
    /// nothing; an on-device-only one (excluded context) needs no ChatGPT account.
    private func preflight(_ field: FocusedField, job: JobType) async -> RewritePreflight {
        let gate = await gate(field)
        var signIn: RewriteNotice?
        if case .proceed(let access) = gate, access.cloudAllowed { signIn = await signInNotice(for: job) }
        let decision = RewriteFlow.preflight(gate: gate, signIn: signIn)
        if decision == .refuse { NSSound.beep() }
        return decision
    }

    /// What the rewrite may use, from the frontmost window's context.
    private func gate(_ field: FocusedField) async -> RewriteGate {
        let sample = await windows.readContext()
        return gate(field, sample: sample, rules: policy())
    }

    private func gate(_ field: FocusedField, sample: FrontmostWindowReader.ContextSample?, rules: CapturePolicy) -> RewriteGate {
        // FocusedFieldReader admits only the onboarding practice field in Remora's process.
        if field.handle.pid == ProcessInfo.processInfo.processIdentifier { return .proceed(.fieldOnlyCloud) }
        return RewriteFlow.gate(context: sample?.context, contextPID: sample?.identity.pid,
                                fieldPID: field.handle.pid, fieldBundleID: field.bundleID,
                                policy: rules, paused: isPaused())
    }

    /// The user's exclusions; unreadable rules fail closed (nothing is capturable).
    private func policy() -> CapturePolicy {
        do { return CapturePolicy(userRules: try ExclusionStore(db).all().compactMap(ExclusionRule.init(pattern:))) } catch {
            Self.log.error("exclusions unreadable; rewrite uses the field only")
            return .denyAll
        }
    }

    /// The request, with the live window (title and text) only when the context may be used. The
    /// window read is bounded: on timeout the rewrite goes on without it.
    private func makeRequest(field: FocusedField, mode: RewriteMode, fieldValue: String, access: RewriteAccess,
                             includeLiveText: Bool = true) async -> RewriteRequest {
        var window: WindowRead?
        if access.windowContextAllowed, !includeLiveText {
            let rules = policy()
            if let sample = await windows.readContext(), sample.identity.pid == field.handle.pid,
               rules.shouldCapture(sample.context) {
                window = WindowRead(context: sample.context, text: "")
            }
        } else if access.windowContextAllowed {
            let policy = policy()
            window = await Self.readWindow(windows, policy: policy, timeout: Self.windowReadTimeout)
            // Only the field's own window, and only if it is still capturable now.
            if let w = window, w.context.bundleID != field.bundleID || !policy.shouldCapture(w.context)
                || BuiltInSkipList.isPasswordVault(host: w.context.domain) {
                window = nil
            }
        }
        let context = window?.context
        let text = includeLiveText && window?.text.isEmpty == false ? window?.text : nil
        return RewriteRequest(mode: mode, fieldValue: fieldValue, app: field.app, bundleID: field.bundleID,
                              surface: RewriteFlow.surface(app: field.app, bundleID: field.bundleID, context: context),
                              windowTitle: context?.windowTitle, liveWindowText: text,
                              memoryAllowed: access.memoryAllowed, logAllowed: access.logAllowed,
                              cloudAllowed: access.cloudAllowed)
    }

    private struct WindowRead: Sendable {
        var context: WindowContext
        var text: String
    }

    private nonisolated static func readWindow(_ windows: FrontmostWindowReader, policy: CapturePolicy,
                                               timeout: Duration) async -> WindowRead? {
        await withTaskGroup(of: WindowRead?.self) { group in
            group.addTask {
                guard let read = try? await windows.readFrontmost(policy: policy) else { return nil }
                return WindowRead(context: read.context, text: read.text)
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()  // a cancelled read short-circuits its remaining AX calls
            return first
        }
    }

    /// Stores the output (redacted, only when logging is allowed) and schedules its outcome check.
    /// Returns the `inline_outputs` id.
    @discardableResult
    private func record(_ output: RewriteOutput, request: RewriteRequest, original: String, instruction: String?,
                        spoken: Bool = false, handle: any FieldHandle) async -> Int64? {
        guard request.logAllowed else { return nil }
        do {
            // A spoken instruction is a transcript: the row is kept, the instruction never is.
            guard let id = try await engine.recordInserted(output, request: request, original: original,
                                                           instruction: instruction, spoken: spoken) else { return nil }
            if isRunning { outcomes.schedule(id: id, handle: handle, inserted: output.replacement) }
            return id
        } catch {
            Self.log.error("inline output not stored: \(String(describing: type(of: error)), privacy: .public)")
            return nil
        }
    }

    /// Re-gates the 45 s outcome check: capture not paused, the field's process frontmost and
    /// capturable under the current rules, not a vault, the field still focused. Fails closed.
    private func mayRecordOutcome(_ handle: any FieldHandle) async -> Bool {
        guard isRunning, !isPaused() else { return false }
        let sample = await windows.readContext()
        let focused = await Task.detached(priority: .utility) { handle.isFocused() }.value
        return RewriteFlow.mayRecordOutcome(paused: isPaused(), context: sample?.context, contextPID: sample?.identity.pid,
                                            fieldPID: handle.pid, policy: policy(), fieldFocused: focused)
    }

    private func perform(_ action: RewriteNotice.Action) {
        switch action {
        case .openSettings:
            closeEditBar()
            openAccountSettings()
        case .manageUsage:
            NSWorkspace.shared.open(SIWC.usageSettingsURL)
        case .openMicrophoneSettings:
            closeEditBar()
            dictation?.perform(.openMicrophoneSettings)
        case .openDictationSettings:
            closeEditBar()
            dictation?.perform(.openDictationSettings)
        }
    }

    private static func clamp(_ r: NSRange, _ s: String) -> NSRange {
        let length = s.utf16.count
        let lower = min(max(r.location, 0), length)
        return NSRange(location: lower, length: min(max(r.length, 0), length - lower))
    }
}

@MainActor
private final class WeakRewriteController {
    weak var value: RewriteController?
}

/// A chord as shown in Settings, e.g. "⇧⌘G".
@MainActor
enum ChordName {
    static func string(_ c: KeyChord) -> String { c.modifierSymbols + keyName(c.keyCode) }

    private static let special: [UInt32: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟", 76: "⌤",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
        109: "F10", 103: "F11", 111: "F12",
    ]

    /// What the key types on the current layout (no modifiers), upper-cased.
    static func keyName(_ code: UInt32) -> String {
        if let name = special[code] { return name }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "Key \(code)" }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        let name: String? = data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return nil }
            var deadKeys: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(base.assumingMemoryBound(to: UCKeyboardLayout.self), UInt16(code),
                                        UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeys, chars.count, &length, &chars)
            return status == noErr && length > 0 ? String(utf16CodeUnits: chars, count: length) : nil
        }
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Key \(code)" }
        return name.uppercased()
    }
}
