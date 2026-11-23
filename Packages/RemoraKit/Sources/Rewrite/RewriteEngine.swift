import Foundation
import LLM
import Redaction
import Retrieval
import Storage
import os

public struct RewriteRequest: Sendable {
    public var mode: RewriteMode
    public var fieldValue: String
    public var app: String
    public var bundleID: String?
    public var surface: String
    /// For an excluded or uncaptured context the caller passes nil here and in `liveWindowText`:
    /// the engine never reads window context on its own.
    public var windowTitle: String?
    public var liveWindowText: String?
    public var memoryAllowed: Bool
    /// False for excluded contexts: nothing is stored in `inline_outputs`.
    public var logAllowed: Bool
    /// Whether field context may go to a cloud model. Typed Insert can instead send the prompt alone.
    public var cloudAllowed: Bool
    public init(mode: RewriteMode, fieldValue: String, app: String, bundleID: String?, surface: String,
                windowTitle: String?, liveWindowText: String?, memoryAllowed: Bool, logAllowed: Bool,
                cloudAllowed: Bool) {
        self.mode = mode; self.fieldValue = fieldValue; self.app = app; self.bundleID = bundleID
        self.surface = surface; self.windowTitle = windowTitle; self.liveWindowText = liveWindowText
        self.memoryAllowed = memoryAllowed; self.logAllowed = logAllowed; self.cloudAllowed = cloudAllowed
    }
}

public struct RewriteOutput: Sendable, Equatable {
    public var replacement: String
    /// UTF-16 range of the request's field value to replace.
    public var range: NSRange
    public var callID: Int64
    /// The backend that answered; nil when unknown.
    public var backend: LLMBackend?
    public init(replacement: String, range: NSRange, callID: Int64, backend: LLMBackend? = nil) {
        self.replacement = replacement; self.range = range; self.callID = callID; self.backend = backend
    }
}

public enum RewriteError: Error, Sendable, Equatable {
    case emptyResult, emptyQuestion, tooLong, unreadableField
    /// The selection lies wholly outside the field (it changed since it was read): nothing to rewrite.
    case selectionOutOfBounds
    /// The text to replace holds an attachment (U+FFFC) that a plain-text write would drop.
    case richContent
}

/// Runs rewrites and Edit rounds. Privacy rule (`RewriteFlow.gate`): the caller decides per request
/// whether window context, memory and logging are allowed, and whether the cloud may be used
/// (`cloudAllowed`; false in contexts Remora does not capture: the on-device model only, failing
/// closed when it is unavailable).
public actor RewriteEngine {
    public static let maxFieldChars = 30_000
    private static let log = Logger(subsystem: "dev.remora", category: "rewrite")

    private let llm: LLMService
    private let context: ContextAssembler
    private let outputs: InlineOutputStore
    private let calls: LLMCallStore
    private let redactor: Redactor
    private let now: @Sendable () -> Date

    public init(llm: LLMService, context: ContextAssembler, outputs: InlineOutputStore, calls: LLMCallStore,
                redactor: Redactor = .init(), now: @escaping @Sendable () -> Date = Date.init) {
        self.llm = llm; self.context = context; self.outputs = outputs; self.calls = calls
        self.redactor = redactor; self.now = now
    }

    /// `onDelta` is provisional progress only (the call may still fail or be retried); the returned
    /// output is the only result.
    /// A `.selection` outside the field is clamped to it; one that clamps to nothing throws
    /// `.selectionOutOfBounds` (an empty selection stays an insertion at the caret).
    public func rewrite(_ r: RewriteRequest, onDelta: (@Sendable (String) -> Void)? = nil) async throws -> RewriteOutput {
        if case .question(let q) = r.mode, q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw RewriteError.emptyQuestion }
        guard r.fieldValue.utf16.count <= Self.maxFieldChars else { throw RewriteError.tooLong }

        var mode = r.mode
        let range: NSRange, original: String
        var keepsDraftSpacing = false
        let whole = NSRange(location: 0, length: r.fieldValue.utf16.count)
        switch r.mode {
        case .selection(let sel):
            range = try SelectionRange.nonEmpty(sel, in: r.fieldValue) ?? SelectionRange.clamp(sel, to: whole.length)
            original = (r.fieldValue as NSString).substring(with: range)
            mode = .selection(range)
        case .full:
            range = whole
            original = r.fieldValue
        case .draft:
            range = NSRange(location: 0, length: 0)
            original = ""
        case .draftAtCaret(let location):
            guard (0...whole.length).contains(location) else { throw RewriteError.selectionOutOfBounds }
            range = NSRange(location: location, length: 0)
            original = ""
            keepsDraftSpacing = true
        case .question:
            range = whole
            original = ""
        }

        let queryText: String
        if case .question(let q) = mode { queryText = q } else { queryText = r.fieldValue }
        let ctx = await assemble(r, fieldText: queryText)
        let prompt = RewritePrompt.make(mode: mode, fieldValue: r.fieldValue, context: ctx, app: r.app,
                                        windowTitle: r.windowTitle.map(redactor.redact), now: now())
        return try await run(.rewrite, prompt, original: original, range: range, cloudAllowed: r.cloudAllowed,
                             keepsDraftSpacing: keepsDraftSpacing, onDelta: onDelta)
    }

    /// `text` is the current target text; `fullRange` is where it sits in the field.
    /// An empty instruction throws `.emptyQuestion`.
    public func edit(instruction: String, text: String, fullRange: NSRange, request r: RewriteRequest) async throws -> RewriteOutput {
        if instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw RewriteError.emptyQuestion }
        guard text.utf16.count <= Self.maxFieldChars else { throw RewriteError.tooLong }
        let ctx = await assemble(r, fieldText: text)
        let prompt = RewritePrompt.edit(instruction: instruction, text: text, context: ctx, app: r.app, now: now())
        return try await run(.editMode, prompt, original: text, range: fullRange, cloudAllowed: r.cloudAllowed, onDelta: nil)
    }

    /// Drafts from a typed instruction for the original caret or selection. If the field must
    /// stay local, use a prompt that has no field, app, window, or memory data.
    public func compose(instruction: String, selection: NSRange?, request r: RewriteRequest) async throws -> RewriteOutput {
        guard instruction.contains(where: { !$0.isWhitespace }) else { throw RewriteError.emptyQuestion }
        let length = r.fieldValue.utf16.count
        guard length <= Self.maxFieldChars else { throw RewriteError.tooLong }
        guard selection != nil || length == 0 else { throw RewriteError.unreadableField }
        let range = selection ?? NSRange(location: 0, length: 0)
        guard range == SelectionRange.clamp(range, to: length) else { throw RewriteError.selectionOutOfBounds }
        let original = (r.fieldValue as NSString).substring(with: range)
        try RewriteFlow.checkEditable(original)

        let prompt: PromptParts
        if r.cloudAllowed {
            let ctx = await assemble(r, fieldText: instruction)
            prompt = RewritePrompt.compose(instruction: instruction, fieldValue: r.fieldValue, range: range,
                                           context: ctx, app: r.app, windowTitle: r.windowTitle.map(redactor.redact),
                                           now: now())
        } else {
            prompt = RewritePrompt.composePromptOnly(instruction)
        }
        return try await run(.editMode, prompt, original: original, range: range, cloudAllowed: true,
                             keepsDraftSpacing: true, onDelta: nil)
    }

    /// Writes a redacted `inline_outputs` row and links the call to it; nil when logging is not allowed.
    /// A non-nil `instruction` marks an Edit-mode round. A `spoken` instruction (dictated, i.e. a
    /// transcript) is never stored: the row is the same Edit-mode row with no instruction.
    public func recordInserted(_ o: RewriteOutput, request r: RewriteRequest, original: String, instruction: String?,
                               spoken: Bool = false) throws -> Int64? {
        guard r.logAllowed else { return nil }
        let mode: InlineMode = instruction != nil ? .edit : InlineMode(r.mode)
        let stored = spoken ? nil : instruction
        let row = try outputs.insert(InlineOutput(
            createdAt: now(), llmCallID: o.callID > 0 ? o.callID : nil, mode: mode, app: r.app, bundleID: r.bundleID,
            surface: r.surface, original: redactor.redact(original), instruction: stored.map(redactor.redact),
            result: redactor.redact(o.replacement)))
        guard let id = row.id else { return nil }
        if o.callID > 0 { try calls.setArtifact(callID: o.callID, table: "inline_outputs", id: id) }
        return id
    }

    /// Classifies what became of an inserted text and stores the outcome. The classifier sees the raw
    /// text; what is stored passes through the redactor (`finalText` only for `.edited`, capped).
    @discardableResult
    public func recordOutcome(outputID: Int64, inserted: String, fieldNow: String?, at: Date) throws -> InlineOutcome? {
        let outcome = OutcomeClassifier.classify(inserted: inserted, fieldNow: fieldNow)
        let final = outcome == .edited ? fieldNow.map { String(redactor.redact($0).prefix(20_000)) } : nil
        try outputs.recordOutcome(id: outputID, outcome: outcome, finalText: final, at: at)
        return outcome
    }

    // MARK: -

    /// Memory only when the gate allowed it (`memoryAllowed`); query expansion follows the
    /// rewrite's own `cloudAllowed`. The assembler bounds its memory part in time.
    private func assemble(_ r: RewriteRequest, fieldText: String) async -> RewriteContext {
        let req = ContextRequest(fieldText: fieldText, windowTitle: r.windowTitle, liveWindowText: r.liveWindowText,
                                 app: r.app, bundleID: r.bundleID, surface: r.surface,
                                 memoryAllowed: r.memoryAllowed, now: now(), cloudAllowed: r.cloudAllowed)
        do { return try await context.context(for: req) } catch {
            Self.log.error("context assembly failed")
            // Same budget as the assembler: never send the whole live window on the fallback path.
            let window = r.liveWindowText.map { context.cutWindow(redactor.redact($0), field: redactor.redact(fieldText)) }
            return RewriteContext(windowText: window)
        }
    }

    private func run(_ job: JobType, _ prompt: PromptParts, original: String, range: NSRange, cloudAllowed: Bool,
                     keepsDraftSpacing: Bool = false, onDelta: (@Sendable (String) -> Void)?) async throws -> RewriteOutput {
        // `cloudAllowed == false` (an excluded context): the on-device model or nothing; the service
        // fails closed with `.onDeviceUnavailable` and never calls the cloud.
        let result = try await llm.complete(job, instructions: prompt.instructions, input: prompt.input,
                                            cloudAllowed: cloudAllowed, onDelta: onDelta)
        let cleaned = OutputCleaner.clean(result.text, original: original, keepsDraftSpacing: keepsDraftSpacing)
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RewriteError.emptyResult }
        return RewriteOutput(replacement: cleaned, range: range, callID: result.callID, backend: result.route.backend)
    }
}
