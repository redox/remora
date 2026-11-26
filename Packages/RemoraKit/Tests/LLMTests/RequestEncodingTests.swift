import Testing
import Foundation
@testable import LLM
import Storage

private func json(_ d: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: d) as? [String: Any])
}

@Test func bodyHasRequiredFieldsAndNoForbiddenOnes() throws {
    let o = try json(ResponsesRequestEncoder.body(.init(model: "gpt-6.1-terra", instructions: "I", input: [.user("hi")], reasoning: .low)))
    #expect(o["store"] as? Bool == false && o["stream"] as? Bool == true && o["instructions"] as? String == "I")
    #expect(Set(o.keys).isSubset(of: ResponsesRequestEncoder.allowedTopLevelKeys))
    #expect((o["reasoning"] as? [String: String])?["effort"] == "low")
    let items = try #require(o["input"] as? [[String: Any]])
    #expect(items.first?["role"] as? String == "user" && items.first?["content"] as? String == "hi")
}

@Test func omitsReasoningWhenNil() throws {
    let o = try json(ResponsesRequestEncoder.body(.init(model: "m", instructions: "I", input: [.user("x")], reasoning: nil)))
    #expect(o["reasoning"] == nil && o["tools"] == nil && o["tool_choice"] == nil && o["text"] == nil)
}

@Test(arguments: ["temperature", "max_output_tokens", "previous_response_id", "metadata", "user", "truncation", "top_p", "background", "safety_identifier"])
func validateRejectsForbidden(_ key: String) {
    #expect(throws: LLMError.forbiddenField(key)) {
        try ResponsesRequestEncoder.validate(["model": "m", "store": false, "stream": true, key: 1])
    }
}

@Test func validateRejectsUnknownKeyStoreStreamSystemAndMinimal() {
    #expect(throws: LLMError.forbiddenField("zzz")) { try ResponsesRequestEncoder.validate(["store": false, "stream": true, "zzz": 1]) }
    #expect(throws: LLMError.self) { try ResponsesRequestEncoder.validate(["store": true, "stream": true]) }
    #expect(throws: LLMError.self) { try ResponsesRequestEncoder.validate(["store": false, "stream": false]) }
    #expect(throws: LLMError.self) {
        try ResponsesRequestEncoder.validate(["store": false, "stream": true, "input": [["role": "system", "content": "x"]]])
    }
    #expect(throws: LLMError.self) {
        try ResponsesRequestEncoder.validate(["store": false, "stream": true, "reasoning": ["effort": "minimal"]])
    }
}

@Test func toolsAreNamespaced() throws {
    let tool = FunctionTool(name: "get_weather", description: "d", parameters: .object(["type": .string("object")]))
    let call = FunctionCall(callID: "c1", namespace: "remora", name: "get_weather", arguments: "{}")
    let o = try json(ResponsesRequestEncoder.body(.init(
        model: "m", instructions: "I",
        input: [.user("x"), .functionCall(call), .functionCallOutput(callID: "c1", output: "sunny")],
        reasoning: .low, tools: [tool], toolChoiceRequired: true)))
    let t0 = try #require((o["tools"] as? [[String: Any]])?.first)
    #expect(t0["type"] as? String == "namespace" && t0["name"] as? String == "remora")
    let inner = try #require((t0["tools"] as? [[String: Any]])?.first)
    #expect(inner["type"] as? String == "function" && inner["name"] as? String == "get_weather")
    #expect(o["tool_choice"] as? String == "required")
    let items = try #require(o["input"] as? [[String: Any]])
    #expect(items[1]["type"] as? String == "function_call" && items[1]["call_id"] as? String == "c1")
    #expect(items[2]["type"] as? String == "function_call_output" && items[2]["output"] as? String == "sunny")
}

@Test func jsonSchemaFormat() throws {
    let o = try json(ResponsesRequestEncoder.body(.init(
        model: "m", instructions: "I", input: [.user("x")], reasoning: .low,
        format: .jsonSchema(name: "out", schema: .object(["type": .string("object")]), strict: true))))
    let f = try #require((o["text"] as? [String: Any])?["format"] as? [String: Any])
    #expect(f["type"] as? String == "json_schema" && f["strict"] as? Bool == true && f["name"] as? String == "out")
}

@Test func defaultTiersMatchSpec() {
    #expect(JobType.rewrite.defaultTier == .large && JobType.hourChronicle.defaultTier == .small
            && JobType.dictationCleanup.defaultTier == .small && JobType.workingMemory.defaultTier == .small && JobType.queryExpansion.defaultTier == .small
            && JobType.salientFlags.defaultTier == .small && JobType.evidenceCheck.defaultTier == .small
            && JobType.chat.defaultEffort == nil && JobType.rewrite.defaultEffort == .low)
    #expect(JobType.memoryDigest.rawValue == "memory_digest" && JobType.memoryDigest.defaultTier == .large)
    #expect(JobType.hourChronicle.rawValue == "hour_chronicle" && JobType.allCases.count == 26)
}

@Test func newJobTypesRoute() {
    #expect(JobType.chatFold.defaultTier == .small && !JobType.chatFold.isBackground
            && JobType.reminderPrompt.defaultTier == .large && JobType.reminderPrompt.isBackground)
    #expect(JobType.chatFold.rawValue == "chat_fold" && JobType.reminderPrompt.rawValue == "reminder_prompt")
    // Addendum §A: chat and proactive writers are large; triage, checks and folds are small.
    for j in [JobType.chat, .morningBrief, .eveningWrap, .nudgeWrite, .reminderPrompt] { #expect(j.defaultTier == .large, "\(j)") }
    for j in [JobType.nudgeTriage, .evidenceCheck, .chatFold] { #expect(j.defaultTier == .small, "\(j)") }
}

@Test func backgroundJobsAreTheOnesThatYieldToUsageBackoff() {
    #expect(JobType.hourChronicle.isBackground && JobType.memoryDigest.isBackground && !JobType.rewrite.isBackground)
    #expect(!JobType.chatFold.isBackground && JobType.reminderPrompt.isBackground)
}

@Test func errorStatusAndRetryability() {
    #expect(LLMError.usageLimit.callStatus == .limit && LLMError.cancelled.callStatus == .cancelled && LLMError.unauthorized.callStatus == .failed)
    #expect(LLMError.http(status: 502).isRetryable && !LLMError.http(status: 400).isRetryable && LLMError.transport(code: -1001).isRetryable)
    #expect(LLMError.temporarilyUnavailable(code: nil).isRetryable && !LLMError.usageLimit.isRetryable)
}
