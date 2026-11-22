import Foundation

enum ResponsesRequestEncoder {
    static let allowedTopLevelKeys: Set<String> = ["model", "instructions", "input", "store", "stream", "reasoning", "text", "tools", "tool_choice"]
    static let forbiddenKeys: Set<String> = [
        "background", "conversation", "max_output_tokens", "max_tool_calls", "metadata", "moderation",
        "multi_agent", "prompt", "prompt_cache_retention", "safety_identifier", "temperature",
        "top_logprobs", "top_p", "truncation", "user", "previous_response_id",
    ]

    static func body(_ r: LLMRequest) throws -> Data {
        var o: [String: Any] = [
            "model": r.model, "instructions": r.instructions, "store": false, "stream": true,
            "input": r.input.map(inputObject),
        ]
        if let e = r.reasoning { o["reasoning"] = ["effort": e.rawValue] }
        if case .jsonSchema(let name, let schema, let strict) = r.format {
            o["text"] = ["format": ["type": "json_schema", "name": name, "schema": schema.foundation, "strict": strict] as [String: Any]]
        }
        if !r.tools.isEmpty {
            let fns: [[String: Any]] = r.tools.map {
                ["type": "function", "name": $0.name, "description": $0.description, "parameters": $0.parameters.foundation, "strict": $0.strict]
            }
            o["tools"] = [["type": "namespace", "name": "remora", "description": "Remora tools", "tools": fns] as [String: Any]]
            if r.toolChoiceRequired { o["tool_choice"] = "required" }
        }
        try validate(o)
        return try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
    }

    private static func inputObject(_ i: InputItem) -> [String: Any] {
        switch i {
        case .user(let t): return ["role": "user", "content": t]
        case .assistant(let t): return ["role": "assistant", "content": t]
        case .functionCall(let c):
            var d: [String: Any] = ["type": "function_call", "call_id": c.callID, "name": c.name, "arguments": c.arguments]
            if let ns = c.namespace { d["namespace"] = ns }
            return d
        case .functionCallOutput(let id, let out): return ["type": "function_call_output", "call_id": id, "output": out]
        }
    }

    static func validate(_ json: [String: Any]) throws {
        for k in json.keys.sorted() where forbiddenKeys.contains(k) { throw LLMError.forbiddenField(k) }
        for k in json.keys.sorted() where !allowedTopLevelKeys.contains(k) { throw LLMError.forbiddenField(k) }
        if let items = json["input"] as? [[String: Any]], items.contains(where: { ($0["role"] as? String) == "system" }) {
            throw LLMError.forbiddenField("input.role=system")
        }
        if let r = json["reasoning"] as? [String: Any], (r["effort"] as? String) == "minimal" {
            throw LLMError.forbiddenField("reasoning.effort=minimal")
        }
        if (json["store"] as? Bool) != false { throw LLMError.forbiddenField("store") }
        if (json["stream"] as? Bool) != true { throw LLMError.forbiddenField("stream") }
    }
}
