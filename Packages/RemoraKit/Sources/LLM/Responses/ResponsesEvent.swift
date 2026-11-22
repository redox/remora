import Foundation

enum ResponsesEvent: Equatable {
    case textDelta(String)
    case outputItemDone(FunctionCall?)
    case completed(LLMUsage)
    /// The server's message text is dropped on purpose: it must never reach a log or an error.
    case failed(code: String?)
    case incomplete(reason: String?)
    case error(code: String?)
    case other(String)

    static func decode(_ data: String) -> ResponsesEvent? {
        guard data != "[DONE]",
              let o = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any],
              let type = o["type"] as? String else { return nil }
        let response = o["response"] as? [String: Any]
        switch type {
        case "response.output_text.delta":
            return .textDelta(o["delta"] as? String ?? "")
        case "response.output_item.done":
            guard let it = o["item"] as? [String: Any], (it["type"] as? String) == "function_call" else { return .outputItemDone(nil) }
            return .outputItemDone(FunctionCall(callID: it["call_id"] as? String ?? "", namespace: it["namespace"] as? String,
                                                name: it["name"] as? String ?? "", arguments: it["arguments"] as? String ?? ""))
        case "response.completed":
            let u = response?["usage"] as? [String: Any] ?? [:]
            let inD = u["input_tokens_details"] as? [String: Any]
            let outD = u["output_tokens_details"] as? [String: Any]
            return .completed(LLMUsage(inputTokens: u["input_tokens"] as? Int ?? 0, cachedInputTokens: inD?["cached_tokens"] as? Int ?? 0,
                                       outputTokens: u["output_tokens"] as? Int ?? 0, reasoningTokens: outD?["reasoning_tokens"] as? Int ?? 0))
        case "response.failed":
            let e = (response?["error"] ?? o["error"]) as? [String: Any]
            return .failed(code: e?["code"] as? String)
        case "response.incomplete":
            let d = (response?["incomplete_details"] ?? o["incomplete_details"]) as? [String: Any]
            return .incomplete(reason: d?["reason"] as? String)
        case "error":
            let e = o["error"] as? [String: Any]
            return .error(code: (o["code"] as? String) ?? (e?["code"] as? String))
        default:
            return .other(type)
        }
    }
}
