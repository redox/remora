import AppKit
import Assistant
import Foundation
import Observation
import os
import Storage

/// The chat panel's state: stored turns, the turn being streamed, the open confirmation card and
/// the session's undoable receipts. Turns run one at a time (`send` is refused while one runs; the
/// agent serializes too). Never logs message content: only counts, statuses and error type names.
@MainActor @Observable
final class ChatModel {
    /// An action receipt from this session, with its undo state. Stored turns keep only the
    /// receipt's summary, so only live receipts can be undone.
    struct ReceiptChip: Identifiable, Equatable {
        enum Undo: Equatable { case available, working, done, note(String) }
        let id = UUID()
        let receipt: ActionReceipt
        var undo: Undo

        init(_ receipt: ActionReceipt) {
            self.receipt = receipt
            undo = receipt.undo == nil ? .done : .available
        }
    }

    /// The newest turns shown (older ones are folded away from the model, and from the panel).
    static let shownTurns = 200

    private(set) var turns: [ChatTurn] = []
    private(set) var inboxKinds: [Int64: InboxKind] = [:]
    private(set) var streamingText = ""
    private(set) var activeTool: String?
    private(set) var isStreaming = false
    private(set) var pendingConfirmation: ActionProposal?
    private(set) var unseenCount = 0
    /// The user's text of the running turn (shown until the stored pair is reloaded).
    private(set) var sendingText: String?
    /// Receipts of the running turn.
    private(set) var liveReceipts: [ReceiptChip] = []
    /// Receipts of this session's finished turns, by assistant turn id.
    private(set) var receipts: [Int64: [ReceiptChip]] = [:]
    /// A storage error of a user action, for display.
    private(set) var notice: String?
    /// Shown for a few seconds after a card expired unanswered.
    private(set) var cardNotice: String?
    /// "Clear chat history" is running: nothing is sent until it ends.
    private(set) var clearing = false
    /// A message details popover is open (it takes key focus from the panel).
    private(set) var detailsOpen = false
    /// The composer's field editor (the panel's first responder), for IME state and ⇧Enter.
    @ObservationIgnored var fieldEditor: (() -> NSTextView?)?
    var draft = ""
    private(set) var editingTurnID: Int64?
    @ObservationIgnored private var draftBeforeEditing: String?
    /// A turn to scroll to (an inbox message opened from a notification).
    var scrollTarget: Int64?
    /// Bumped to move keyboard focus to the composer.
    private(set) var focusToken = 0
    /// Focus was asked for before the chat view existed: it takes it when it appears.
    @ObservationIgnored private var focusPending = false
    /// Told when a turn starts or ends (the bar's Esc stops a stream).
    @ObservationIgnored var onStreamingChange: ((Bool) -> Void)?

    @ObservationIgnored private let agent: ChatAgent
    @ObservationIgnored private let db: AppDatabase
    @ObservationIgnored private let store: ChatStore
    @ObservationIgnored private let inbox: InboxStore
    @ObservationIgnored private let calls: LLMCallStore
    @ObservationIgnored private let toolKinds: @Sendable (String) -> ToolKind?
    @ObservationIgnored private let reminders: ReminderEngine
    @ObservationIgnored private let effects: any ActionEffects
    @ObservationIgnored private var turnTask: Task<Void, Never>?
    @ObservationIgnored private var confirmation: (proposal: ActionProposal, answer: CheckedContinuation<Bool, Never>)?
    @ObservationIgnored private var seen: Set<Int64> = []
    @ObservationIgnored private var cardNoticeTask: Task<Void, Never>?
    static let expiredNotice = "Request expired — nothing was changed."
    @ObservationIgnored private static let log = Logger(subsystem: "dev.remora", category: "chat")

    init(agent: ChatAgent, db: AppDatabase, toolKinds: @escaping @Sendable (String) -> ToolKind?,
         reminders: ReminderEngine, effects: any ActionEffects) {
        self.agent = agent
        self.db = db
        store = ChatStore(db)
        inbox = InboxStore(db)
        calls = LLMCallStore(db)
        self.toolKinds = toolKinds
        self.reminders = reminders
        self.effects = effects
        // A turn left pending by a quit or crash reads "Interrupted." from now on.
        do {
            let n = try store.failPending(at: .now)
            if n > 0 { Self.log.info("interrupted turns marked: \(n, privacy: .public)") }
        } catch {
            Self.log.error("failPending failed: \(String(describing: type(of: error)), privacy: .public)")
        }
        reload()
    }

    var canSend: Bool { ChatPresentation.canSend(draft: draft, isStreaming: isStreaming, clearing: clearing) }

    var latestUserTurnID: Int64? { turns.last { $0.role == .user }?.id }
    var canEditLastMessage: Bool { latestUserTurnID != nil && editingTurnID == nil && !isStreaming && !clearing }
    var editingHasActions: Bool {
        guard let editingTurnID else { return false }
        return turns.contains { ($0.id ?? 0) > editingTurnID && $0.inboxID == nil && $0.tools.contains { $0.receipt != nil } }
    }

    func editLastMessage() {
        guard canEditLastMessage, let turn = turns.last(where: { $0.role == .user }) else { return }
        if editingTurnID == nil { draftBeforeEditing = draft }
        editingTurnID = turn.id
        draft = turn.text
        notice = nil
        requestFocus()
    }

    func cancelEditing() {
        guard editingTurnID != nil, !isStreaming else { return }
        draft = draftBeforeEditing ?? ""
        editingTurnID = nil
        draftBeforeEditing = nil
        requestFocus()
    }

    /// An input method is composing in the composer (Return and Esc are its own).
    var isComposing: Bool { fieldEditor?()?.hasMarkedText() ?? false }

    /// ⇧Enter: a newline at the caret.
    func insertNewline() {
        if let editor = fieldEditor?() {
            editor.insertNewlineIgnoringFieldEditor(nil)
        } else {
            draft += "\n"
        }
    }

    func detailsAppeared() { detailsOpen = true }
    func detailsDisappeared() { detailsOpen = false }

    var activity: String? {
        activeTool.map { ChatPresentation.activity(tool: $0, kind: toolKinds($0)) }
    }

    // MARK: - Turns

    func send() {
        guard canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        send(text, replacing: editingTurnID)
    }

    /// Sends a starter chip's question.
    func ask(_ text: String) {
        guard ChatPresentation.canSend(draft: text, isStreaming: isStreaming, clearing: clearing) else { return }
        send(text)
    }

    private func send(_ text: String, replacing userTurnID: Int64? = nil) {
        isStreaming = true
        sendingText = text
        streamingText = ""
        activeTool = nil
        liveReceipts = []
        notice = nil
        clearCardNotice()
        onStreamingChange?(true)
        // Events arrive off the main actor: a stream keeps their order.
        let (events, sink) = AsyncStream.makeStream(of: ChatEvent.self)
        let agent = agent
        let ask: @Sendable (ActionProposal) async -> Bool = { [weak self] p in
            await self?.confirm(p) ?? false
        }
        turnTask = Task { [weak self] in
            let consumer = Task { @MainActor [weak self] in
                for await e in events { self?.handle(e) }
            }
            let turn = await agent.send(text, replacing: userTurnID, confirm: ask, onEvent: { sink.yield($0) })
            sink.finish()
            await consumer.value
            self?.finish(turn, submittedText: text, replacing: userTurnID)
        }
    }

    func stop() {
        guard isStreaming else { return }
        answerConfirmation(false)
        turnTask?.cancel()
    }

    private func handle(_ e: ChatEvent) {
        switch e {
        case .historyReplaced(let userID, let assistantID):
            reload()
            // The new pair is already stored, but its provisional UI is shown until finish.
            turns.removeAll { $0.id == userID || $0.id == assistantID }
        case .textDelta(let d): streamingText += d
        case .toolStarted(let name): activeTool = name
        case .toolFinished(_, _, let receipt):
            activeTool = nil
            if let receipt { liveReceipts.append(ReceiptChip(receipt)) }
        case .roundFinished:
            // The next round's deltas start a new paragraph (the stored text joins rounds the same way).
            if !streamingText.isEmpty, !streamingText.hasSuffix("\n\n") { streamingText += "\n\n" }
        }
    }

    private func finish(_ turn: ChatTurn, submittedText: String, replacing userTurnID: Int64?) {
        if let id = turn.id, !liveReceipts.isEmpty { receipts[id] = liveReceipts }
        if turn.id == nil { notice = "Could not save the chat." }
        Self.log.info("turn ended \(turn.status.rawValue, privacy: .public) \(turn.error ?? "-", privacy: .public)")
        answerConfirmation(false)
        turnTask = nil
        isStreaming = false
        if userTurnID != nil {
            if turn.id == nil {
                draft = submittedText
                notice = turn.error == "edit_unavailable"
                    ? "That message can no longer be edited. Cancel to write a new message."
                    : "Could not resend the message. Your edit is still here."
            } else {
                editingTurnID = nil
                draft = draftBeforeEditing ?? ""
                draftBeforeEditing = nil
            }
        }
        sendingText = nil
        streamingText = ""
        activeTool = nil
        liveReceipts = []
        reload()
        onStreamingChange?(false)
    }

    // MARK: - Confirmation

    /// Suspends until the card is answered; a cancelled turn (Stop, the card's expiry) answers false.
    private func confirm(_ p: ActionProposal) async -> Bool {
        let id = p.id
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                answerConfirmation(false)  // never two cards: the older one is declined
                guard !Task.isCancelled else { return c.resume(returning: false) }
                confirmation = (p, c)
                pendingConfirmation = p
            }
        } onCancel: {
            // Stop answers the card before cancelling, so a card still open here has expired.
            Task { @MainActor [weak self] in
                guard let self, self.confirmation?.proposal.id == id else { return }
                self.answerConfirmation(false)
                self.showCardNotice(Self.expiredNotice)
            }
        }
    }

    func resolveConfirmation(_ allow: Bool) { answerConfirmation(allow) }

    private func showCardNotice(_ text: String) {
        cardNotice = text
        cardNoticeTask?.cancel()
        cardNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.cardNotice = nil
        }
    }

    private func clearCardNotice() {
        cardNoticeTask?.cancel()
        cardNoticeTask = nil
        cardNotice = nil
    }

    private func answerConfirmation(_ allow: Bool) {
        guard let c = confirmation else { return }
        confirmation = nil
        pendingConfirmation = nil
        c.answer.resume(returning: allow)
    }

    // MARK: - Undo

    func undo(_ chipID: UUID) {
        guard let (key, index) = locate(chipID), chip(key, index).undo == .available,
              let token = chip(key, index).receipt.undo else { return }
        let generation = chip(key, index).receipt.generation
        setUndo(key, index, .working)
        let reminders = reminders, db = db, effects = effects
        Task { [weak self] in
            let state: ReceiptChip.Undo
            do {
                let r = try await ActionTools.perform(token, generation: generation, reminders: reminders, db: db,
                                                      effects: effects)
                state = r.message.map(ReceiptChip.Undo.note) ?? .done
            } catch is DataGeneration.Stale {
                state = .note("Your data was deleted since, so there is nothing to undo.")
            } catch {
                Self.log.error("undo failed: \(String(describing: type(of: error)), privacy: .public)")
                state = .note("Could not undo this.")
            }
            guard let self, let (key, index) = self.locate(chipID) else { return }
            self.setUndo(key, index, state)
        }
    }

    /// nil key: the running turn.
    private func locate(_ id: UUID) -> (Int64?, Int)? {
        if let i = liveReceipts.firstIndex(where: { $0.id == id }) { return (nil, i) }
        for (k, chips) in receipts { if let i = chips.firstIndex(where: { $0.id == id }) { return (k, i) } }
        return nil
    }

    private func chip(_ key: Int64?, _ i: Int) -> ReceiptChip {
        key.flatMap { receipts[$0]?[i] } ?? liveReceipts[i]
    }

    private func setUndo(_ key: Int64?, _ i: Int, _ u: ReceiptChip.Undo) {
        if let key { receipts[key]?[i].undo = u } else { liveReceipts[i].undo = u }
    }

    // MARK: - History

    func clearHistory() async {
        guard !clearing else { return }
        clearing = true
        defer { clearing = false }
        stop()
        if let turnTask { await turnTask.value }
        cancelEditing()
        clearCardNotice()
        let store = store
        do {
            try await Task.detached { try store.clear() }.value
            receipts = [:]
            seen = []
        } catch {
            Self.log.error("clear chat failed: \(String(describing: type(of: error)), privacy: .public)")
            notice = "Could not clear the chat."
        }
        reload()
    }

    /// Delete-all succeeded: stops the running turn (its card is declined), drops this session's
    /// receipts and shows the now-empty history.
    func dataDeleted() async {
        stop()
        if let turnTask { await turnTask.value }
        cancelEditing()
        clearCardNotice()
        receipts = [:]
        seen = []
        notice = nil
        reload()
    }

    /// Re-reads the newest turns and the unseen count (after a turn, and when the inbox delivers).
    func reload() {
        do {
            turns = try store.turns(limit: Self.shownTurns)
            inboxKinds = try ChatPresentation.inboxKinds(turns, db: db)
        } catch {
            Self.log.error("chat reload failed: \(String(describing: type(of: error)), privacy: .public)")
        }
        refreshUnseen()
    }

    private func refreshUnseen() {
        do { unseenCount = try inbox.unseenCount() } catch {
            Self.log.error("unseen count failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    /// Inbox messages shown in the expanded list become seen.
    func markVisibleSeen(_ ids: [Int64]) {
        let fresh = ids.filter { !seen.contains($0) }
        guard !fresh.isEmpty else { return }
        seen.formUnion(fresh)
        do { try inbox.markSeen(fresh, at: .now) } catch {
            Self.log.error("mark seen failed: \(String(describing: type(of: error)), privacy: .public)")
        }
        refreshUnseen()
    }

    /// Scrolls to the turn delivering `inboxID` (reloading first: it may have just arrived).
    func reveal(inboxID: Int64) {
        reload()
        scrollTarget = turns.first { $0.inboxID == inboxID }?.id
    }

    func details(for t: ChatTurn) async -> [GeneratedBy] {
        // Store reads may wait for SQLite; opening a popover must not block typing or scrolling.
        await Task.detached { [calls, ids = t.llmCallIDs, log = Self.log] in
            ids.compactMap { id in
                do { return try calls.generatedBy(callID: id) } catch {
                    log.error("call details unreadable: \(String(describing: type(of: error)), privacy: .public)")
                    return nil
                }
            }
        }.value
    }

    func requestFocus() {
        focusPending = true
        focusToken += 1
    }

    /// True once per `requestFocus` (the view that takes the focus consumes it).
    func takeFocusRequest() -> Bool {
        defer { focusPending = false }
        return focusPending
    }
}
