import Foundation
import GRDB
import LLM
import MeetingImport
import Redaction
import Retrieval
import Storage
import Synchronization
import os

/// What the chat UI hears while a turn runs. Deltas are provisional (see `LLMService`); the
/// returned `ChatTurn` is the result.
public enum ChatEvent: Sendable, Equatable {
    case historyReplaced(userTurnID: Int64, assistantTurnID: Int64)
    case textDelta(String)
    case toolStarted(String)
    case toolFinished(name: String, ok: Bool, receipt: ActionReceipt?)
    case roundFinished(callID: Int64)
}

public struct ChatLimits: Sendable {
    /// Model rounds per turn; the last one is sent without tools, so it must answer.
    public var maxRounds = 8
    /// Estimated tokens of replayed history.
    public var historyBudget = 12_000
    /// Fold when the unfolded history exceeds this many estimated tokens…
    public var foldTrigger = 24_000
    /// …keeping the newest turns unfolded.
    public var keepRecent = 10
    /// One tool output, in characters.
    public var toolOutputChars = 24_000
    /// The whole turn (every round and tool run): past it the turn fails with "timeout". The clock
    /// stops while a confirmation card is open (cards expire on their own after 10 minutes).
    public var turnTimeout: Duration = .seconds(300)
    /// Function calls run per round; extra calls get an error output and are not run.
    public var maxCallsPerRound = 8
    public init() {}
}

/// The chat turn timed out (`ChatLimits.turnTimeout`).
public struct ChatTimeout: Error, Equatable { public init() {} }

/// Runs chat turns: the streaming tool loop over `LLMService` (job `chat`), with taint-aware
/// actions, budgeted history and background folding.
///
/// Memory: the chat always has the user's memory and memory tools. Pausing capture stops
/// capturing, not remembering (controller ruling). The chat never receives the frontmost
/// window's text.
///
/// Safety: a turn is **tainted** (every action asks the user first, Task 4 `ActionPolicy`) from
/// its start when its prompt carries captured or derived text (digest, identity, working memory,
/// an earlier-conversation summary, replayed inbox messages, a replayed turn stored `tainted` or
/// one that ran a non-trusted tool), and after any tool run that is not a `.trustedRead`. The
/// final value is stored on the assistant turn, so the taint survives the history budget.
/// Cancelling the turn declines a pending confirmation, so nothing runs. Turns run one at a
/// time. Model output is redacted before storage. Never logs content: only counts, statuses and
/// error codes.
public actor ChatAgent {
    private static let log = Logger(subsystem: "dev.remora", category: "chat")

    private let db: AppDatabase
    private let llm: LLMService
    private let toolbox: ChatToolbox
    private let store: ChatStore
    private let calls: LLMCallStore
    private let limits: ChatLimits
    private let calendar: @Sendable () -> Calendar
    private let now: @Sendable () -> Date
    private let redactor = Redactor()
    private let folder: ChatFolder
    private var folding: Task<Void, Never>?
    /// The latest turn: the next one starts after it ends.
    private var lastTurn: Task<ChatTurn, Never>?

    public init(db: AppDatabase, llm: LLMService, toolbox: ChatToolbox, store: ChatStore, calls: LLMCallStore,
                limits: ChatLimits = .init(), calendar: @escaping @Sendable () -> Calendar,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.db = db; self.llm = llm; self.toolbox = toolbox; self.store = store; self.calls = calls
        self.limits = limits; self.calendar = calendar; self.now = now
        folder = ChatFolder(db: db, store: store, llm: llm, limits: limits)
    }

    // MARK: send

    /// Runs one turn after the previous one ended (turns never interleave). Cancelling the caller
    /// cancels this turn.
    public func send(_ text: String, replacing userTurnID: Int64? = nil, confirm: @escaping @Sendable (ActionProposal) async -> Bool,
                     onEvent: @escaping @Sendable (ChatEvent) -> Void) async -> ChatTurn {
        let previous = lastTurn
        let turn = Task { [self] in
            _ = await previous?.value
            // A fold may still contain the old wording. Finish it before invalidating summaries
            // so it cannot write that wording back after the edit's transaction commits.
            if userTurnID != nil { await folding?.value }
            return await run(text, replacing: userTurnID, confirm: confirm, onEvent: onEvent)
        }
        lastTurn = turn
        return await withTaskCancellationHandler { await turn.value } onCancel: { turn.cancel() }
    }

    private func run(_ text: String, replacing userTurnID: Int64?, confirm: @escaping @Sendable (ActionProposal) async -> Bool,
                     onEvent: @escaping @Sendable (ChatEvent) -> Void) async -> ChatTurn {
        let started = now()
        let generation = try? DataGeneration.current(db)

        // Revision, history read and new pair are atomic: a failed save keeps the old exchange.
        let prior: (turns: [ChatTurn], summary: ChatSummary?, kinds: [Int64: InboxKind])
        var assistant: ChatTurn
        do {
            try Task.checkCancellation()
            let store = store, userText = redactor.redact(text)
            let prepared = try await db.writer.write { d in
                if let userTurnID { try store.prepareForResend(userTurnID: userTurnID, in: d) }
                let (turns, summary) = try store.replayable(in: d)
                let kinds = try Self.inboxKinds(turns, in: d)
                let user = try store.append(ChatTurn(createdAt: started, role: .user, text: userText, status: .complete), in: d)
                let reply = try store.append(ChatTurn(createdAt: started, role: .assistant, text: "", status: .pending), in: d)
                return (turns, summary, kinds, user, reply)
            }
            prior = (prepared.0, prepared.1, prepared.2)
            assistant = prepared.4
            if userTurnID != nil, let userID = prepared.3.id, let replyID = assistant.id {
                onEvent(.historyReplaced(userTurnID: userID, assistantTurnID: replyID))
            }
        } catch is ChatStore.EditError {
            return ChatTurn(createdAt: started, role: .assistant, text: "", status: .failed, error: "edit_unavailable")
        } catch is CancellationError {
            return ChatTurn(createdAt: started, role: .assistant, text: "", status: .cancelled)
        } catch {
            Self.log.error("chat turn not stored")
            return ChatTurn(createdAt: started, role: .assistant, text: "", status: .failed, error: "storage")
        }

        let memory = (try? MemoryContext.base(db: db, surface: "chat", now: started)) ?? .empty
        var replayable = prior.turns
        if replayable.contains(where: SearchSavedNotesTool.used),
           (try? await SavedNoteStore(db).canUseChatContext(since: started, now: now())) != true {
            replayable.removeAll(where: SearchSavedNotesTool.used)
        }
        let historyIDs = Set(replayable.flatMap { $0.recordingIDs ?? [] })
        if !historyIDs.isEmpty {
            let allowed = (try? await LocalMeetingLibrary(db: db).allowedChatIDs(historyIDs, since: started, at: now())) ?? []
            replayable.removeAll { !($0.recordingIDs ?? []).isSubset(of: allowed) }
        }
        let kept = ChatHistory.kept(turns: replayable, budgetTokens: limits.historyBudget, inboxKinds: prior.kinds)
        let history = ChatHistory.input(turns: kept, summary: prior.summary, budgetTokens: limits.historyBudget, inboxKinds: prior.kinds)
        let instructions = ChatPrompt.instructions(memory: memory, earlier: history.earlier, now: started,
                                                   calendar: calendar())
        let tainted = startsTainted(memory: memory, earlier: history.earlier, kept: kept)
        let hasSavedNoteContext = kept.contains(where: SearchSavedNotesTool.used)

        let state = TurnState(tainted: tainted, recordingIDs: Set(kept.flatMap { $0.recordingIDs ?? [] }))
        let assistantID = assistant.id
        let input = history.items + [.user(text)]
        let status: ChatTurnStatus
        var code: String?
        do {
            let clock = TurnClock(limit: limits.turnTimeout)
            try await within(clock) { [self] in
                try await loop(.chat, instructions: instructions, input: input, toolbox: toolbox,
                               confirm: Self.cancellable(confirm, clock: clock), generation: generation,
                               artifactID: assistantID, state: state, onEvent: onEvent,
                               interactiveStarted: started,
                               hasMeetingContext: prior.turns.contains(where: SearchMeetingsTool.used),
                               hasSavedNoteContext: hasSavedNoteContext)
            }
            status = .complete
        } catch {
            (status, code) = Self.outcome(error)
        }

        assistant.text = redactor.redact(state.text)
        assistant.tools = state.traces
        assistant.llmCallIDs = state.callIDs
        assistant.status = status
        assistant.error = code
        assistant.tainted = state.tainted
        assistant.recordingIDs = state.recordingIDs.isEmpty ? nil : state.recordingIDs
        assistant.usedSavedNotes = hasSavedNoteContext || SearchSavedNotesTool.used(in: assistant)
        if status == .complete, assistant.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            assistant.status = .failed
            assistant.error = "no_answer"
        }
        do { try store.update(assistant) } catch { Self.log.error("chat turn update failed") }
        Self.log.info("turn \(assistant.status.rawValue, privacy: .public) \(assistant.error ?? "-", privacy: .public) rounds=\(state.callIDs.count, privacy: .public) tools=\(state.traces.count, privacy: .public)")
        scheduleFold()
        return assistant
    }

    // MARK: answer

    /// A reminder `prompt` (or any one-off question): read-only tools, no history, nothing stored.
    /// Returns the redacted text and the `llm_calls` ids, or throws (`LLMError`, `ChatTimeout`).
    public func answer(prompt: String, job: JobType = .reminderPrompt) async throws -> (text: String, callIDs: [Int64]) {
        let at = now()
        let memory = (try? MemoryContext.base(db: db, surface: "chat", now: at)) ?? .empty
        let instructions = ChatPrompt.instructions(memory: memory, earlier: nil, now: at, calendar: calendar())
        let tools = toolbox.readOnly()
        let state = TurnState(tainted: true)
        do {
            try await within(TurnClock(limit: limits.turnTimeout)) { [self] in
                try await loop(job, instructions: instructions, input: [.user(prompt)], toolbox: tools,
                               confirm: { _ in false }, generation: nil, artifactID: nil, state: state,
                               onEvent: { _ in })
            }
        } catch is ChatTimeout {
            throw ChatTimeout()
        } catch {
            throw Task.isCancelled ? LLMError.cancelled : Self.llmError(error)
        }
        return (redactor.redact(state.text), state.callIDs)
    }

    // MARK: Loop

    private nonisolated func loop(_ job: JobType, instructions: String, input start: [InputItem], toolbox: ChatToolbox,
                                  confirm: @escaping @Sendable (ActionProposal) async -> Bool,
                                  generation: Int?, artifactID: Int64?, state: TurnState,
                                  onEvent: @escaping @Sendable (ChatEvent) -> Void,
                                  interactiveStarted: Date? = nil, hasMeetingContext: Bool = false,
                                  hasSavedNoteContext: Bool = false) async throws {
        var input = start
        var usedMeetings = hasMeetingContext
        var usedSavedNotes = hasSavedNoteContext
        let rounds = max(1, limits.maxRounds)
        for round in 1...rounds {
            if Task.isCancelled { throw LLMError.cancelled }
            let recordingIDs = state.recordingIDs
            if !recordingIDs.isEmpty {
                guard let interactiveStarted,
                      try await LocalMeetingLibrary(db: db).allowedChatIDs(recordingIDs, since: interactiveStarted, at: now()) == recordingIDs
                else { throw LLMError.cancelled }
            }
            if usedMeetings {
                guard let interactiveStarted, try ImportedMeetingStore(db).chatAccessEnabled(),
                      try !SettingsStore(db).isPaused(now: now()),
                      try await db.reader.read({ d in
                          ForgetMarks.chatForgetAt(in: d).map { $0 <= interactiveStarted } ?? true
                      }) else { throw LLMError.cancelled }
            }
            if usedSavedNotes {
                guard let interactiveStarted,
                      try await SavedNoteStore(db).canUseChatContext(since: interactiveStarted, now: now())
                else { throw LLMError.cancelled }
            }
            let offered = round < rounds ? toolbox.definitions : []
            state.beginRound()
            let r = try await llm.complete(job, instructions: instructions, input: input, tools: offered,
                                           onDelta: { d in state.delta(d); onEvent(.textDelta(d)) })
            state.finishRound(text: r.text, callID: r.callID)
            if let artifactID {
                do { try calls.setArtifact(callID: r.callID, table: "chat_turns", id: artifactID) } catch {
                    Self.log.error("chat artifact link failed")
                }
            }
            onEvent(.roundFinished(callID: r.callID))
            if r.functionCalls.isEmpty || offered.isEmpty { return }

            if !r.text.isEmpty { input.append(.assistant(r.text)) }
            input += r.functionCalls.map(InputItem.functionCall)
            // Sequentially: a read's taint must be in force before the next call runs.
            for (i, c) in r.functionCalls.enumerated() {
                if Task.isCancelled { throw LLMError.cancelled }
                guard i < limits.maxCallsPerRound else {
                    input.append(.functionCallOutput(callID: c.callID, output: Self.tooManyCalls(limits.maxCallsPerRound)))
                    continue
                }
                onEvent(.toolStarted(c.name))
                let context = ToolContext(now: now(), calendar: calendar(), turnTainted: state.tainted, confirm: confirm,
                                          generation: generation)
                let run = await toolbox.run(c, context: context)
                if !run.recordingIDs.isEmpty { state.includeRecordings(run.recordingIDs) }
                if c.name == SearchMeetingsTool.name, !run.isError { usedMeetings = true }
                if c.name == SearchSavedNotesTool.name, !run.isError { usedSavedNotes = true }
                // Anything but Remora's own bookkeeping (reads of captured or derived text, action
                // outputs such as a forget card's listing, unknown tools) taints the rest of the turn.
                if toolbox.kind(of: c.name) != .trustedRead { state.taint() }
                input.append(.functionCallOutput(callID: c.callID, output: Self.cap(run.output, limits.toolOutputChars)))
                state.trace(ToolTrace(name: String(c.name.prefix(64)), ok: !run.isError, confirmed: run.confirmed,
                                      receipt: run.receipt.map { redactor.redact($0.summary) }))
                onEvent(.toolFinished(name: c.name, ok: !run.isError, receipt: run.receipt))
            }
        }
    }

    static func tooManyCalls(_ max: Int) -> String {
        "Not run: at most \(max) tool calls are run per round. Call it again if it is still needed."
    }

    /// Captured or derived text already in the prompt taints the turn from its start.
    private func startsTainted(memory: BaseMemory, earlier: String?, kept: [ChatTurn]) -> Bool {
        if memory.digest != nil || memory.identity != nil || !memory.workingMemory.isEmpty || earlier != nil { return true }
        return kept.contains { t in
            t.tainted || t.inboxID != nil || t.tools.contains { toolbox.kind(of: $0.name) != .trustedRead }
        }
    }

    static func llmError(_ error: any Error) -> LLMError {
        if let e = error as? LLMError { return e }
        if error is CancellationError { return .cancelled }
        return .configuration(code: "error")
    }

    static func cap(_ s: String, _ limit: Int) -> String {
        guard s.count > limit else { return s }
        return String(s.prefix(limit)) + ChatToolbox.truncationSuffix
    }

    /// The turn's status and stable error code (the UI maps codes to copy).
    static func outcome(_ error: any Error) -> (ChatTurnStatus, String?) {
        if error is ChatTimeout { return (.failed, "timeout") }
        if Task.isCancelled { return (.cancelled, nil) }
        let e = Self.llmError(error)
        switch e {
        case .cancelled: return (.cancelled, nil)
        case .usageLimit: return (.failed, "usage_limit")
        case .notSignedIn, .needsSignIn, .planUsageDisabled: return (.failed, "sign_in")
        case .temporarilyUnavailable, .transport: return (.failed, "unavailable")
        default: return (.failed, e.errorCode ?? "error")
        }
    }

    /// Runs `body`; once `clock` has run out it is cancelled and `ChatTimeout` is thrown.
    private nonisolated func within(_ clock: TurnClock, _ body: @escaping @Sendable () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { g in
            g.addTask { try await body() }
            g.addTask {
                try await clock.expire()
                throw ChatTimeout()
            }
            defer { g.cancelAll() }
            try await g.next()
        }
    }

    /// The user's answer, or false as soon as the turn is cancelled (the sheet may stay up: its
    /// late answer is ignored, so nothing runs).
    /// The turn clock stops while the card is open.
    static func cancellable(_ confirm: @escaping @Sendable (ActionProposal) async -> Bool, clock: TurnClock? = nil)
        -> @Sendable (ActionProposal) async -> Bool {
        { proposal in
            if Task.isCancelled { return false }
            clock?.pause()
            defer { clock?.resume() }
            let answer = OneShot()
            let asker = Task { answer.resolve(await confirm(proposal)) }
            let accepted = await withTaskCancellationHandler {
                await answer.wait()
            } onCancel: {
                answer.resolve(false)
                asker.cancel()
            }
            return accepted && !Task.isCancelled
        }
    }

    static func inboxKinds(_ turns: [ChatTurn], in d: Database) throws -> [Int64: InboxKind] {
        let ids = turns.compactMap(\.inboxID)
        guard !ids.isEmpty else { return [:] }
        var out: [Int64: InboxKind] = [:]
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        for row in try Row.fetchAll(d, sql: "SELECT id, kind FROM inbox_messages WHERE id IN (\(marks))",
                                    arguments: StatementArguments(ids)) {
            if let kind = InboxKind(rawValue: row["kind"]) { out[row["id"]] = kind }
        }
        return out
    }

    // MARK: Folding

    /// One fold at a time, off the turn.
    private func scheduleFold() {
        if let folding, !folding.isCancelled { return }
        let folder = folder, now = now
        folding = Task.detached { [weak self] in
            await folder.foldIfNeeded(now: now())
            await self?.foldDone()
        }
    }

    private func foldDone() { folding = nil }

    /// Waits for a running fold (tests and shutdown).
    public func waitForFold() async { await folding?.value }
}

/// What a turn accumulated, readable after a cancel or failure.
final class TurnState: Sendable {
    private struct S {
        var rounds: [String] = []
        var partial = ""
        var callIDs: [Int64] = []
        var traces: [ToolTrace] = []
        var recordingIDs: Set<UUID>
        var tainted: Bool
    }

    private let s: Mutex<S>

    init(tainted: Bool = false, recordingIDs: Set<UUID> = []) {
        s = Mutex(S(recordingIDs: recordingIDs, tainted: tainted))
    }

    func includeRecordings(_ ids: Set<UUID>) { s.withLock { $0.recordingIDs.formUnion(ids) } }
    var recordingIDs: Set<UUID> { s.withLock { $0.recordingIDs } }

    func taint() { s.withLock { $0.tainted = true } }
    var tainted: Bool { s.withLock { $0.tainted } }

    func beginRound() { s.withLock { $0.partial = "" } }
    func delta(_ d: String) { s.withLock { $0.partial += d } }
    func finishRound(text: String, callID: Int64) {
        s.withLock { $0.rounds.append(text); $0.partial = ""; $0.callIDs.append(callID) }
    }
    func trace(_ t: ToolTrace) { s.withLock { $0.traces.append(t) } }

    /// Every round's text joined with a blank line, then any streamed text of an unfinished round.
    var text: String {
        s.withLock { ($0.rounds + [$0.partial]).filter { !$0.isEmpty }.joined(separator: "\n\n") }
    }
    var callIDs: [Int64] { s.withLock { $0.callIDs } }
    var traces: [ToolTrace] { s.withLock { $0.traces } }
}

/// A Bool answered once; later answers are ignored.
final class OneShot: Sendable {
    private struct S {
        var value: Bool?
        var waiter: CheckedContinuation<Bool, Never>?
    }

    private let s = Mutex(S())

    func resolve(_ v: Bool) {
        let waiter: CheckedContinuation<Bool, Never>? = s.withLock { state in
            guard state.value == nil else { return nil }
            state.value = v
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: v)
    }

    func wait() async -> Bool {
        await withCheckedContinuation { c in
            let ready: Bool? = s.withLock {
                if let v = $0.value { return v }
                $0.waiter = c
                return nil
            }
            if let ready { c.resume(returning: ready) }
        }
    }
}

/// The turn's time budget. It runs only while no confirmation card is open, so a card the user is
/// still reading never times the turn out (the card expires on its own).
final class TurnClock: Sendable {
    private struct S {
        var used: Duration = .zero
        var since: ContinuousClock.Instant?
        var pauses = 0
    }

    private let limit: Duration
    private let s: Mutex<S>

    init(limit: Duration) {
        self.limit = limit
        s = Mutex(S(since: ContinuousClock.now))
    }

    func pause() {
        s.withLock {
            if $0.pauses == 0, let since = $0.since { $0.used += ContinuousClock.now - since; $0.since = nil }
            $0.pauses += 1
        }
    }

    func resume() {
        s.withLock {
            $0.pauses = max(0, $0.pauses - 1)
            if $0.pauses == 0, $0.since == nil { $0.since = ContinuousClock.now }
        }
    }

    /// The running time left; nil while paused.
    var remaining: Duration? {
        s.withLock { st in st.since.map { limit - (st.used + (ContinuousClock.now - $0)) } }
    }

    /// Returns once the running time reaches the limit; throws when cancelled.
    func expire() async throws {
        while true {
            guard let left = remaining else {
                try await Task.sleep(for: .milliseconds(100))
                continue
            }
            if left <= .zero { return }
            try await Task.sleep(for: min(left, .milliseconds(500)))
        }
    }
}

/// `prompt` reminders run through `answer(prompt:job:)`: read-only tools, no history, nothing stored.
extension ChatAgent: ReminderAnswering {}
