import Foundation
import Storage
import Testing
@testable import Assistant

private func failed(_ code: String?) -> ChatTurn {
    ChatTurn(createdAt: .now, role: .assistant, text: "", status: .failed, error: code)
}

@Test func errorCopyByCode() {
    #expect(ChatPresentation.errorCopy(failed("usage_limit")) == .init(text: "Usage limit reached.", action: .manageUsage))
    #expect(ChatPresentation.errorCopy(failed("sign_in")) == .init(text: "Sign in with ChatGPT to chat.", action: .openSettings))
    #expect(ChatPresentation.errorCopy(failed("unavailable"))?.text == "ChatGPT is unavailable right now. Try again.")
    // Raw LLMError codes of `.temporarilyUnavailable` / `.transport` read the same.
    #expect(ChatPresentation.errorCopy(failed("temporarily_unavailable"))?.text == "ChatGPT is unavailable right now. Try again.")
    #expect(ChatPresentation.errorCopy(failed("server_overloaded"))?.text == "Something went wrong.")
    #expect(ChatPresentation.errorCopy(failed("transport_-1009"))?.text == "ChatGPT is unavailable right now. Try again.")
    #expect(ChatPresentation.errorCopy(failed("interrupted"))?.text == "Interrupted.")
    #expect(ChatPresentation.errorCopy(failed("not_eligible"))?.text == "ChatGPT plan usage isn't available for this account.")
    #expect(ChatPresentation.errorCopy(failed("timeout"))?.text == "Something went wrong.")
    #expect(ChatPresentation.errorCopy(failed(nil))?.text == "Something went wrong.")
}

@Test func cancelledTurnsEndStoppedAndCompleteOnesHaveNoCopy() {
    let stopped = ChatPresentation.errorCopy(ChatTurn(createdAt: .now, role: .assistant, text: "partial", status: .cancelled))
    #expect(stopped == .init(text: "Stopped.", action: nil, italic: true))
    #expect(ChatPresentation.errorCopy(ChatTurn(createdAt: .now, role: .assistant, text: "hi", status: .complete)) == nil)
    #expect(ChatPresentation.errorCopy(ChatTurn(createdAt: .now, role: .user, text: "hi", status: .failed)) == nil)
}

@Test func activityLabelsByToolKind() {
    #expect(ChatPresentation.activity(tool: "search_memory", kind: .untrustedRead) == "Looking at your memory…")
    #expect(ChatPresentation.activity(tool: "get_usage", kind: .trustedRead) == "Looking at your memory…")
    #expect(ChatPresentation.activity(tool: "get_remora_guide", kind: .trustedRead) == "Checking the guide…")
    #expect(ChatPresentation.activity(tool: "add_exclusion", kind: .action(.confirm)) == "Working…")
    #expect(ChatPresentation.activity(tool: "mystery", kind: nil) == "Working…")
}

@Test func inboxLabels() {
    #expect(ChatPresentation.label(.morningBrief) == "Morning brief")
    #expect(ChatPresentation.label(.eveningWrap) == "Evening wrap-up")
    #expect(ChatPresentation.label(.nudge) == "Nudge")
    #expect(ChatPresentation.label(.reminder) == "Reminder")
}

@Test func costShowsEstimateOrDash() {
    #expect(ChatPresentation.cost(nil) == "—")
    #expect(ChatPresentation.cost(0.0042) == "est. $0.0042")
    #expect(ChatPresentation.cost(1.234) == "est. $1.23")
    #expect(ChatPresentation.cost(0) == "est. $0.00")
}

@Test func totalsSumTokensAndPricedCosts() {
    let a = GeneratedBy(model: "m", backend: "siwc", inputTokens: 100, outputTokens: 10, estCostUSD: 0.01, at: .now)
    let b = GeneratedBy(model: "m", backend: "siwc", inputTokens: 50, outputTokens: 5, estCostUSD: nil, at: .now)
    let t = ChatPresentation.totals([a, b])
    #expect(t.inputTokens == 150 && t.outputTokens == 15)
    #expect(t.estCostUSD == 0.01 && t.someUnpriced)
    let none = ChatPresentation.totals([b])
    #expect(none.estCostUSD == nil && none.someUnpriced)
    #expect(ChatPresentation.totals([]) == .init(inputTokens: 0, outputTokens: 0, estCostUSD: nil, someUnpriced: false))
}

@Test func sendNeedsTextAndAnIdleTurn() {
    #expect(ChatPresentation.canSend(draft: "hi", isStreaming: false))
    #expect(!ChatPresentation.canSend(draft: "  \n ", isStreaming: false))
    #expect(!ChatPresentation.canSend(draft: "hi", isStreaming: true))
    #expect(!ChatPresentation.canSend(draft: "hi", isStreaming: false, clearing: true))
}

@Test func returnNeverApprovesOrSendsWhileACardIsPending() {
    #expect(ChatPresentation.returnKey(shift: false, composing: false, cardPending: false) == .send)
    #expect(ChatPresentation.returnKey(shift: false, composing: false, cardPending: true) == .swallow)
    #expect(ChatPresentation.returnKey(shift: true, composing: false, cardPending: true) == .newline)
    #expect(ChatPresentation.returnKey(shift: true, composing: false, cardPending: false) == .newline)
}

@Test func returnAndEscapeGoToTheInputMethodWhileComposing() {
    #expect(ChatPresentation.returnKey(shift: false, composing: true, cardPending: false) == .passThrough)
    #expect(ChatPresentation.returnKey(shift: true, composing: true, cardPending: true) == .passThrough)
    #expect(!ChatPresentation.barTakesEscape(composing: true))
    #expect(ChatPresentation.barTakesEscape(composing: false))
}

@Test func cardSummaryLeavesRoomForButtonsAndComposer() {
    // Default size: capped at 180.
    #expect(ChatPresentation.cardSummaryMaxHeight(panelHeight: 520, fontSize: 13) == 180)
    // Minimum size: 35 % of the panel at most.
    #expect(ChatPresentation.cardSummaryMaxHeight(panelHeight: 280, fontSize: 13) == 98)
    // Minimum size at 150 %: what the fixed chrome leaves, but never less than one line.
    let tight = ChatPresentation.cardSummaryMaxHeight(panelHeight: 280, fontSize: 19.5)
    #expect(tight + ChatPresentation.cardReservedHeight(fontSize: 19.5) <= 280)
    #expect(tight >= 19.5 * 1.4)
}

@Test func storedReceiptsComeFromToolTraces() {
    var t = ChatTurn(createdAt: .now, role: .assistant, text: "ok", status: .complete)
    t.tools = [ToolTrace(name: "search_memory", ok: true),
               ToolTrace(name: "add_exclusion", ok: true, confirmed: true, receipt: "Never capture example.com"),
               ToolTrace(name: "pause_capture", ok: false, receipt: nil)]
    #expect(ChatPresentation.storedReceipts(t) == ["Never capture example.com"])
}

@Test func inboxKindsAreReadForTurnsThatDeliverMessages() throws {
    let db = try AppDatabase.inMemory()
    let msg = try db.writer.write { d in
        try InboxStore.insertIfNew(InboxMessage(kind: .eveningWrap, title: "t", body: "b", dedupeKey: "evening:x",
                                                createdAt: .now), in: d)
    }
    let id = try #require(msg?.id)
    let turns = [ChatTurn(createdAt: .now, role: .assistant, text: "b", status: .complete, inboxID: id),
                 ChatTurn(createdAt: .now, role: .user, text: "q", status: .complete)]
    #expect(try ChatPresentation.inboxKinds(turns, db: db) == [id: .eveningWrap])
}

@Test func dictatedWordsPreserveTheTypedChatDraftAndItsSpacing() {
    #expect(ChatPresentation.appendingTranscript(" hello ", to: "") == "hello")
    #expect(ChatPresentation.appendingTranscript("world", to: "hello") == "hello world")
    #expect(ChatPresentation.appendingTranscript("two", to: "one\n") == "one\ntwo")
    #expect(ChatPresentation.appendingTranscript("  ", to: "keep this ") == "keep this ")
}
