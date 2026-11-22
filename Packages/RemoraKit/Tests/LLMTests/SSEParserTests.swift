import Testing
import Foundation
@testable import LLM

private func decodeAll(_ lines: [String]) -> [ResponsesEvent] {
    var p = SSEParser()
    var msgs = lines.flatMap { p.feed(line: $0) }
    msgs += p.finish()
    return msgs.compactMap { ResponsesEvent.decode($0.data) }
}

private func ev(_ type: String, _ extra: String = "") -> [String] {
    ["event: \(type)", #"data: {"type":"\#(type)"\#(extra)}"#, ""]
}

@Test func parsesObservedEventSequence() {
    var lines: [String] = []
    lines += ev("response.created") + ev("response.in_progress") + ev("response.output_item.added") + ev("response.content_part.added")
    lines += ev("response.output_text.delta", #","delta":"Bon""#) + ev("response.output_text.delta", #","delta":"jour !""#)
    lines += ev("response.metadata") + ev("response.output_text.done") + ev("response.content_part.done") + ev("response.output_item.done")
    lines += ev("response.completed", #","response":{"usage":{"input_tokens":21,"input_tokens_details":{"cached_tokens":0},"output_tokens":6,"output_tokens_details":{"reasoning_tokens":0}}}"#)
    #expect(decodeAll(lines) == [
        .other("response.created"), .other("response.in_progress"), .other("response.output_item.added"), .other("response.content_part.added"),
        .textDelta("Bon"), .textDelta("jour !"),
        .other("response.metadata"), .other("response.output_text.done"), .other("response.content_part.done"), .outputItemDone(nil),
        .completed(.init(inputTokens: 21, cachedInputTokens: 0, outputTokens: 6, reasoningTokens: 0)),
    ])
}

@Test func parserHandlesCRLFCommentsMultilineAndUnterminatedTail() {
    var p = SSEParser()
    #expect(p.feed(line: ": ping").isEmpty)
    #expect(p.feed(line: "event: x\r").isEmpty)
    #expect(p.feed(line: "data: a\r").isEmpty)
    #expect(p.feed(line: "data: b").isEmpty)
    #expect(p.feed(line: "") == [SSEMessage(event: "x", data: "a\nb")])
    #expect(p.feed(line: "data: tail").isEmpty)
    #expect(p.finish() == [SSEMessage(event: nil, data: "tail")])
    #expect(p.finish().isEmpty)
}

@Test func doneAndGarbageDecodeToNil() {
    #expect(ResponsesEvent.decode("[DONE]") == nil && ResponsesEvent.decode("nope") == nil)
}

@Test func missingUsageFieldsReadAsZero() {
    #expect(ResponsesEvent.decode(#"{"type":"response.completed","response":{"usage":{"input_tokens":5}}}"#)
            == .completed(.init(inputTokens: 5, cachedInputTokens: 0, outputTokens: 0, reasoningTokens: 0)))
    #expect(ResponsesEvent.decode(#"{"type":"response.completed","response":{}}"#) == .completed(.zero))
}

@Test func decodesFunctionCallItem() {
    let d = #"{"type":"response.output_item.done","item":{"type":"function_call","call_id":"call_1","namespace":"remora","name":"get_weather","arguments":"{\"city\":\"Paris\"}"}}"#
    #expect(ResponsesEvent.decode(d) == .outputItemDone(FunctionCall(callID: "call_1", namespace: "remora", name: "get_weather", arguments: #"{"city":"Paris"}"#)))
}

@Test func decodesMidStreamFailureAndOthers() {
    #expect(ResponsesEvent.decode(#"{"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"m"}}}"#)
            == .failed(code: "subscription_sharing_usage_limit_exceeded"))
    #expect(ResponsesEvent.decode(#"{"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}"#) == .incomplete(reason: "max_output_tokens"))
    #expect(ResponsesEvent.decode(#"{"type":"error","code":"x"}"#) == .error(code: "x"))
}

@Test func oversizedEventSetsOverflowAndIsDropped() {
    var p = SSEParser()
    let chunk = "data: " + String(repeating: "a", count: 1_048_576)
    var msgs: [SSEMessage] = []
    for _ in 0..<9 { msgs += p.feed(line: chunk) }
    #expect(p.overflowed)
    msgs += p.feed(line: "")
    #expect(msgs.isEmpty)
}

@Test func eventsJustUnderTheCapAreDelivered() {
    var p = SSEParser()
    _ = p.feed(line: "data: " + String(repeating: "a", count: 4 * 1_048_576))
    let out = p.feed(line: "")
    #expect(!p.overflowed && out.count == 1)
}
