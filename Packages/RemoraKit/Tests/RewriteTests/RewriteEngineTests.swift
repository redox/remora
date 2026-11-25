import Foundation
import LLM
import LLMTestSupport
import Redaction
import Retrieval
import Storage
import Testing
@testable import Rewrite

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
private let usage = LLMUsage(inputTokens: 10, cachedInputTokens: 0, outputTokens: 2, reasoningTokens: 0)
private let spikeSlugs = ["gpt-6.2-sol", "gpt-6.2-astra", "gpt-6.1-terra", "gpt-6.1-sol", "gpt-6-astra", "gpt-6-sol", "gpt-6-luna"]
private let spike = spikeSlugs.map { ModelInfo(slug: $0, displayName: $0) }

private struct Env {
    var db: AppDatabase
    var fake: FakeLLMClient
    var engine: RewriteEngine
}

private func env(_ script: [FakeLLMClient.Step]) throws -> Env {
    let db = try AppDatabase.inMemory()
    let fake = FakeLLMClient(script: script)
    let svc = LLMService(siwc: fake, onDevice: FakeLLMClient(backend: .onDevice, script: []),
                         onDeviceAvailability: { .unavailable("test") }, calls: LLMCallStore(db),
                         routing: { RoutingConfig() }, catalog: { spike }, prices: { .empty }, now: { t0 }, retryDelay: .zero)
    let engine = RewriteEngine(llm: svc, context: ContextAssembler(db: db), outputs: InlineOutputStore(db),
                               calls: LLMCallStore(db), now: { t0 })
    return Env(db: db, fake: fake, engine: engine)
}

private func req(_ mode: RewriteMode, _ value: String, log: Bool = true, memory: Bool = true, live: String? = nil) -> RewriteRequest {
    RewriteRequest(mode: mode, fieldValue: value, app: "Mail", bundleID: "com.apple.mail", surface: "mail",
                   windowTitle: "Re: x", liveWindowText: live, memoryAllowed: memory, logAllowed: log, cloudAllowed: true)
}

@Test func engineSelectionReplacesOnlySelection() async throws {
    let e = try env([.delta("tha"), .delta("nks"), .complete(usage)])
    let sel = NSRange(location: 14, length: 5)
    let out = try await e.engine.rewrite(req(.selection(sel), "Bonjour Marc, merci"))
    #expect(out.range == sel && out.replacement == "thanks")
    let r = e.fake.requests[0]
    #expect(r.model == "gpt-6.1-terra")
    let row = try LLMCallStore(e.db).calls(since: .distantPast, limit: 5)[0]
    #expect(row.jobType == "rewrite" && out.callID == row.id)
    #expect(out.backend == .siwc)
}

@Test func rewritingExistingTextInAnExcludedContextNeverCallsTheCloud() async throws {
    // The rewrite tier is cloud, but the request is for an excluded app.
    let db = try AppDatabase.inMemory()
    let cloud = FakeLLMClient(script: [.delta("cloud"), .complete(usage)])
    func engine(_ onDevice: FakeLLMClient, _ availability: OnDeviceAvailability) -> RewriteEngine {
        let svc = LLMService(siwc: cloud, onDevice: onDevice, onDeviceAvailability: { availability },
                             calls: LLMCallStore(db), routing: { RoutingConfig() },
                             catalog: { spike }, prices: { .empty }, now: { t0 }, retryDelay: .zero)
        return RewriteEngine(llm: svc, context: ContextAssembler(db: db), outputs: InlineOutputStore(db),
                             calls: LLMCallStore(db), now: { t0 })
    }
    var r = req(.full, "Salut", log: false, memory: false)
    r.windowTitle = nil
    r.cloudAllowed = false
    let local = FakeLLMClient(backend: .onDevice, script: [.delta("Bonjour"), .complete(usage)])
    let out = try await engine(local, .available).rewrite(r)
    #expect(out.backend == .onDevice && out.replacement == "Bonjour")
    // Unavailable: fails closed with the model's reason.
    await #expect(throws: LLMError.onDeviceUnavailable(reason: "Apple Intelligence is turned off.")) {
        try await engine(FakeLLMClient(backend: .onDevice, script: []), .unavailable("Apple Intelligence is turned off.")).rewrite(r)
    }
    await #expect(throws: LLMError.onDeviceUnavailable(reason: "Apple Intelligence is turned off.")) {
        try await engine(FakeLLMClient(backend: .onDevice, script: []), .unavailable("Apple Intelligence is turned off."))
            .edit(instruction: "shorter", text: "Salut", fullRange: NSRange(location: 0, length: 5), request: r)
    }
    #expect(cloud.requests.isEmpty)
}

@Test func engineReportsTheBackendThatAnswered() async throws {
    let db = try AppDatabase.inMemory()
    let onDevice = FakeLLMClient(backend: .onDevice, script: [.delta("Bonjour"), .complete(usage)])
    let svc = LLMService(siwc: FakeLLMClient(script: []), onDevice: onDevice, onDeviceAvailability: { .available },
                         calls: LLMCallStore(db), routing: { RoutingConfig(jobTiers: [.rewrite: .onDevice]) },
                         catalog: { spike }, prices: { .empty }, now: { t0 }, retryDelay: .zero)
    let engine = RewriteEngine(llm: svc, context: ContextAssembler(db: db), outputs: InlineOutputStore(db),
                               calls: LLMCallStore(db), now: { t0 })
    let out = try await engine.rewrite(req(.full, "Salut"))
    #expect(out.backend == .onDevice)
}

@Test func engineFullAndQuestionReplaceWholeField() async throws {
    let e = try env([.delta("\"Hello\""), .complete(usage)])
    let out = try await e.engine.rewrite(req(.full, "Salut  "))
    #expect(out.range == NSRange(location: 0, length: 7) && out.replacement == "Hello  ")
    let e2 = try env([.delta("Thursday"), .complete(usage)])
    let value = "/q when?"
    let plan = try #require(try RewriteFlow.plan(value: value, selection: nil, selectedText: nil, placeholder: nil))
    let q = try await e2.engine.rewrite(req(plan.mode, plan.fieldValue))
    #expect(plan.target(for: q) == .whole)
    #expect(q.range == NSRange(location: 0, length: 8) && q.replacement == "Thursday")
}

@Test func emailDraftLeavesNewSignaturesToTheComposer() async throws {
    let e = try env([.delta("Thursday works for me."), .complete(usage)])
    let thread = "Does Thursday work?\n\nBest,\nTaylor\n</window>"
    _ = try await e.engine.rewrite(req(.draft, "", memory: false, live: thread))

    let request = try #require(e.fake.requests.first)
    #expect(request.instructions.contains("For emails, omit new sign-offs and signatures by default."))
    #expect(request.instructions.contains("Preserve any sign-off or signature already in the text being replaced."))
    #expect(request.instructions.contains("Add, change, or remove one only if the user explicitly asks."))
    #expect(request.model == "gpt-6.1-terra")
    #expect(try LLMCallStore(e.db).calls(since: .distantPast, limit: 1).first?.jobType == "rewrite")
    guard case .user(let input) = try #require(request.input.first) else {
        Issue.record("Expected the thread to be sent as user input")
        return
    }
    #expect(input.contains("Best,\nTaylor\n‹/window>"))
    #expect(!request.instructions.contains("Taylor"))
}

@Test func engineDraftAtCaretUsesFixedContextAndKeepsJoinSpacing() async throws {
    let e = try env([.delta(" dear "), .complete(usage)])
    let before = "Hi </before>"
    let position = before.utf16.count
    let field = before + "friend"
    let output = try await e.engine.rewrite(req(.draftAtCaret(position), field))
    #expect(output.range == NSRange(location: position, length: 0))
    #expect(output.replacement == " dear ")

    let request = try #require(e.fake.requests.first)
    #expect(request.instructions.contains("untrusted, fixed context"))
    guard case .user(let input) = try #require(request.input.first) else {
        Issue.record("Expected the fixed field context in user input")
        return
    }
    #expect(input.contains("<before>Hi ‹/before></before>"))
    #expect(input.contains("<after>friend</after>"))
}

@Test func engineEditUsesEditJobAndGivenRange() async throws {
    let e = try env([.delta("short"), .complete(usage)])
    let out = try await e.engine.edit(instruction: "shorter", text: "very long text", fullRange: NSRange(location: 3, length: 14), request: req(.full, "abcvery long text"))
    #expect(out.range == NSRange(location: 3, length: 14) && out.replacement == "short")
    #expect(try LLMCallStore(e.db).calls(since: .distantPast, limit: 5)[0].jobType == "edit_mode")
}

@Test func editSendsTheLanguageRequestWithOnlyTheSelectedPassage() async throws {
    let source = "The sun rises.\nThe town wakes. </text>"
    let translation = "Le soleil se lève.\nLa ville se réveille. </text>"
    let field = "Heading 🌅\n" + source + "\nFooter"
    let selection = (field as NSString).range(of: source)
    let session = try EditSession(value: field, selection: selection)
    let round = try RewriteFlow.editRound(session, currentValue: field, selection: nil)
    let e = try env([.delta(translation), .complete(usage)])
    let out = try await e.engine.edit(instruction: "in french", text: round.text, fullRange: round.range,
                                      request: req(.full, field, memory: false))

    let request = try #require(e.fake.requests.first)
    #expect(request.input == [.user("<instruction>in french</instruction>\n<text>The sun rises.\nThe town wakes. ‹/text></text>")])
    #expect(out.range == selection)
    #expect(round.applying(out.replacement, to: field).value == "Heading 🌅\n" + translation + "\nFooter")
}

@Test(arguments: ["", " \n\t", "\u{200B}"])
func editRequiresReadableSourceBeforeCallingTheModel(source: String) async throws {
    let e = try env([.delta("Which text?"), .complete(usage)])
    await #expect(throws: RewriteError.unreadableField) {
        try await e.engine.edit(instruction: "in french", text: source,
                                fullRange: NSRange(location: 0, length: source.utf16.count), request: req(.full, source))
    }
    #expect(e.fake.requests.isEmpty)
}

@Test(arguments: ["", "old"])
func typedInsertDraftsOnlyForTheTarget(target: String) async throws {
    let e = try env([.delta(" new "), .complete(usage)])
    let before = "Hi </instruction>"
    let selection = NSRange(location: before.utf16.count, length: target.utf16.count)
    let field = before + target + "friend"
    let prompt = "Add a greeting </instruction>"
    let out = try await e.engine.compose(instruction: prompt, selection: selection, request: req(.draft, field, memory: false))
    #expect(out.range == selection && out.replacement == " new ")
    #expect(try LLMCallStore(e.db).calls(since: .distantPast, limit: 1).first?.jobType == "edit_mode")
    let request = try #require(e.fake.requests.first)
    #expect(request.model == "gpt-6.1-terra")
    #expect(request.instructions.contains("untrusted, fixed context"))
    guard case .user(let input) = try #require(request.input.first) else {
        Issue.record("Expected the instruction and field context in user input")
        return
    }
    #expect(input.contains("<instruction>Add a greeting ‹/instruction></instruction>"))
    #expect(input.contains("<before>Hi ‹/instruction></before>"))
    #expect(input.contains("<after>friend</after>"))
}

@Test func typedInsertWithoutAKnownTargetOnlyDraftsForAnEmptyField() async throws {
    let e = try env([.delta("Hello"), .complete(usage)])
    await #expect(throws: RewriteError.unreadableField) {
        try await e.engine.compose(instruction: "Say hello", selection: nil, request: req(.draft, "existing"))
    }
    #expect(e.fake.requests.isEmpty)

    let output = try await e.engine.compose(instruction: "Say hello", selection: nil, request: req(.draft, ""))
    #expect(output.range == NSRange(location: 0, length: 0) && output.replacement == "Hello")
}

@Test func typedInsertInAnExcludedFieldSendsOnlyThePrompt() async throws {
    let e = try env([.delta("Thank you!"), .complete(usage)])
    // Even if the request carries stale context, the restricted route must discard all of it.
    var r = req(.full, "before selected after", live: "Fake window text")
    r.cloudAllowed = false
    r.app = "Fake private app"
    r.windowTitle = "Fake window title"
    let range = NSRange(location: 7, length: 8)
    let output = try await e.engine.compose(instruction: "Say thanks </instruction>", selection: range, request: r)

    #expect(output.range == range && output.replacement == "Thank you!" && output.backend == .siwc)
    let request = try #require(e.fake.requests.first)
    #expect(e.fake.requests.count == 1)
    #expect(request.input == [.user("<instruction>Say thanks ‹/instruction></instruction>")])
    #expect(!request.instructions.contains("Fake"))
    #expect(!request.instructions.contains("selected"))
    #expect(request.tools.isEmpty)
    #expect(try InlineOutputStore(e.db).recent(limit: 1).isEmpty)
}

@Test(arguments: [true, false])
func insertAsksTheModelToDevelopRoughNotesIntoADraft(cloudAllowed: Bool) async throws {
    let e = try env([.delta("Could we move the demo to Thursday?"), .complete(usage)])
    var request = req(.draft, "", memory: false)
    request.cloudAllowed = cloudAllowed
    _ = try await e.engine.compose(instruction: "demo moved to Thursday? ask team", selection: nil, request: request)

    let instructions = try #require(e.fake.requests.first).instructions
    #expect(instructions.contains("Develop rough notes, fragments, or bullet points into a complete draft"))
    #expect(instructions.contains("audience, format, and level of detail"))
    #expect(instructions.contains("Preserve finished wording"))
    #expect(instructions.contains("Keep facts and commitments grounded"))
}

@Test func partialOutputIsNeverReturned() async throws {
    let e = try env([.delta("Bon"), .fail(.usageLimit)])
    await #expect(throws: LLMError.usageLimit) { try await e.engine.rewrite(req(.full, "Salut")) }
    #expect(try InlineOutputStore(e.db).recent(limit: 5).isEmpty)
}

@Test func emptyResultThrows() async throws {
    let e = try env([.delta("  \n"), .complete(usage)])
    await #expect(throws: RewriteError.emptyResult) { try await e.engine.rewrite(req(.full, "Salut")) }
}

@Test func emptyQuestionAndTooLongFailBeforeLLM() async throws {
    let e = try env([.complete(usage)])
    await #expect(throws: RewriteError.emptyQuestion) { try await e.engine.rewrite(req(.question(" "), "/q ")) }
    await #expect(throws: RewriteError.tooLong) { try await e.engine.rewrite(req(.full, String(repeating: "a", count: RewriteEngine.maxFieldChars + 1))) }
    #expect(e.fake.requests.isEmpty)
}

@Test func excludedContextSendsNoWindowText() async throws {
    let e = try env([.delta("ok"), .complete(usage)])
    _ = try await e.engine.rewrite(RewriteRequest(mode: .full, fieldValue: "Salut", app: "Bank", bundleID: nil, surface: "bank",
                                                  windowTitle: nil, liveWindowText: nil, memoryAllowed: false, logAllowed: false,
                                                  cloudAllowed: true))
    guard case .user(let text) = e.fake.requests[0].input[0] else { Issue.record("no input"); return }
    #expect(!text.contains("<window>") && !text.contains("<related>") && text.contains("<field>Salut</field>"))
}

@Test func livePromptRedactsWindowAndTitle() async throws {
    let e = try env([.delta("ok"), .complete(usage)])
    _ = try await e.engine.rewrite(req(.draft, "", live: "pay 4111 1111 1111 1111"))
    guard case .user(let text) = e.fake.requests[0].input[0] else { Issue.record("no input"); return }
    #expect(text.contains("[redacted]") && !text.contains("4111"))
}

@Test func recordInsertedRedactsAndLinksCall() async throws {
    let e = try env([.delta("Merci"), .complete(usage)])
    let r = req(.full, "Voici mon IBAN FR76 3000 6000 0112 3456 7890 189")
    let out = try await e.engine.rewrite(r)
    let id = try #require(try await e.engine.recordInserted(out, request: r, original: r.fieldValue, instruction: nil))
    let row = try #require(try InlineOutputStore(e.db).recent(limit: 1).first)
    #expect(row.id == id && row.original.contains("[redacted]") && !row.original.contains("3000") && row.result == "Merci")
    #expect(row.mode == .full && row.llmCallID == out.callID && row.surface == "mail" && row.app == "Mail")
    let call = try #require(try LLMCallStore(e.db).calls(since: .distantPast, limit: 1).first)
    #expect(call.artifactTable == "inline_outputs" && call.artifactID == id)
}

@Test func recordInsertedMarksEditMode() async throws {
    let e = try env([.delta("short"), .complete(usage)])
    let r = req(.full, "long text")
    let out = try await e.engine.edit(instruction: "shorter, my iban FR76 3000 6000 0112 3456 7890 189", text: "long text", fullRange: NSRange(location: 0, length: 9), request: r)
    _ = try await e.engine.recordInserted(out, request: r, original: "long text", instruction: "shorter, my iban FR76 3000 6000 0112 3456 7890 189")
    let row = try #require(try InlineOutputStore(e.db).recent(limit: 1).first)
    #expect(row.mode == .edit && row.instruction?.contains("[redacted]") == true)
}

/// A spoken Edit-mode instruction is a transcript: the row is an Edit-mode row like a typed one, but
/// the instruction itself is never stored.
@Test func recordInsertedNeverStoresASpokenInstruction() async throws {
    let e = try env([.delta("short"), .complete(usage)])
    let r = req(.full, "long text")
    let out = try await e.engine.edit(instruction: "make it shorter", text: "long text", fullRange: NSRange(location: 0, length: 9), request: r)
    let id = try #require(try await e.engine.recordInserted(out, request: r, original: "long text", instruction: "make it shorter", spoken: true))
    let row = try #require(try InlineOutputStore(e.db).recent(limit: 1).first)
    #expect(row.id == id && row.mode == .edit && row.instruction == nil)
    #expect(row.original == "long text" && row.result == "short" && row.llmCallID == out.callID)
    let call = try #require(try LLMCallStore(e.db).calls(since: .distantPast, limit: 1).first)
    #expect(call.artifactTable == "inline_outputs" && call.artifactID == id)
}

@Test func recordInsertedSkippedWhenLogNotAllowed() async throws {
    let e = try env([.delta("Merci"), .complete(usage)])
    let r = req(.full, "Salut", log: false)
    let out = try await e.engine.rewrite(r)
    #expect(try await e.engine.recordInserted(out, request: r, original: "Salut", instruction: nil) == nil)
    #expect(try InlineOutputStore(e.db).recent(limit: 5).isEmpty)
    #expect(try LLMCallStore(e.db).calls(since: .distantPast, limit: 1)[0].artifactTable == nil)
}

@Test func recordOutcomeRedactsFinalText() async throws {
    let e = try env([.delta("Merci"), .complete(usage)])
    let r = req(.full, "Salut")
    let out = try await e.engine.rewrite(r)
    let id = try #require(try await e.engine.recordInserted(out, request: r, original: "Salut", instruction: nil))
    let o = try await e.engine.recordOutcome(outputID: id, inserted: "Merci", fieldNow: "Merci beaucoup, iban FR76 3000 6000 0112 3456 7890 189", at: t0)
    #expect(o == .edited || o == .kept)
    let row = try #require(try InlineOutputStore(e.db).recent(limit: 1).first)
    #expect(row.outcome == o && (row.finalText ?? "[redacted]").contains("[redacted]") && row.finalText?.contains("3000") != true)
}

@Test func contextFallbackCutsLiveWindowText() async throws {
    let e = try env([.delta("ok"), .complete(usage)])
    // Make the assembler fail (memory lookups need the snapshot tables).
    try await e.db.writer.write { try $0.execute(sql: "DROP TABLE style_notes") }
    let live = String(repeating: "a", count: 20_000) + "TAIL"
    _ = try await e.engine.rewrite(req(.draft, "", live: live))
    guard case .user(let text) = e.fake.requests[0].input[0] else { Issue.record("no input"); return }
    let start = try #require(text.range(of: "<window>")), end = try #require(text.range(of: "</window>"))
    let body = text[start.upperBound..<end.lowerBound]
    #expect(body.hasSuffix("TAIL"))
    #expect(body.count <= ContextBudget().windowChars + "Title: Re: x\n".count)
}

@Test func engineClampsOutOfBoundsSelection() async throws {
    let e = try env([.delta("there"), .complete(usage)])
    let out = try await e.engine.rewrite(req(.selection(NSRange(location: 6, length: 99)), "Hello world"))
    #expect(out.range == NSRange(location: 6, length: 5))
    guard case .user(let text) = e.fake.requests[0].input[0] else { Issue.record("no input"); return }
    #expect(text.contains("<selection>world</selection>"))
}

@Test func engineRefusesSelectionClampedToEmpty() async throws {
    let e = try env([.delta("x"), .complete(usage)])
    await #expect(throws: RewriteError.selectionOutOfBounds) {
        try await e.engine.rewrite(req(.selection(NSRange(location: 50, length: 3)), "Hello"))
    }
    #expect(e.fake.requests.isEmpty)
}

@Test func engineEmptySelectionStaysAnInsertion() async throws {
    let e = try env([.delta("X"), .complete(usage)])
    let out = try await e.engine.rewrite(req(.selection(NSRange(location: 2, length: 0)), "Hello"))
    #expect(out.range == NSRange(location: 2, length: 0))
}
