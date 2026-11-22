import Foundation

enum ErrorClassifier {
    static func classify(status: Int, body: Data) -> LLMError {
        var code: String?, param: String?
        if let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
           let e = o["error"] as? [String: Any] {
            code = (e["code"] as? String).map(truncated)
            param = (e["param"] as? String).map(truncated)
        }
        // `{"detail":…}` bodies carry no code; they fall through to the status mapping.
        if let code, let known = mapCode(code, param: param) { return known }
        switch status {
        case 401: return .unauthorized
        case 403: return .forbidden
        // The plan's usage limit only with a subscription usage code or no code; any other code
        // (`rate_limit_exceeded`, …) is a transient throttle worth one retry.
        case 429:
            guard let code, !code.hasPrefix("subscription_sharing_usage_") else { return .usageLimit }
            return .temporarilyUnavailable(code: code)
        case 503: return .temporarilyUnavailable(code: code)
        case 400..<500: return .badRequest(code: code, param: param)
        default: return .http(status: status)
        }
    }

    /// A failure reported inside a stream. Unknown codes (`server_error`, `rate_limit_exceeded`, …)
    /// are treated as transient: the request itself was accepted.
    static func classify(code: String?, param: String?) -> LLMError {
        let code = code.map(truncated)
        if let code, let known = mapCode(code, param: param.map(truncated)) { return known }
        return .temporarilyUnavailable(code: code)
    }

    /// Server-provided codes end up in `LLMError` and `llm_calls.error_code`: keep them short.
    static let maxCodeLength = 64
    static func truncated(_ s: String) -> String { String(s.prefix(maxCodeLength)) }

    private static func mapCode(_ code: String, param: String?) -> LLMError? {
        switch code {
        case "subscription_sharing_usage_limit_exceeded": return .usageLimit
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable": return .temporarilyUnavailable(code: code)
        case "subscription_sharing_user_not_eligible": return .notEligible
        case "subscription_sharing_unsupported_capability": return .unsupported(param: param)
        case "subscription_sharing_route_not_supported", "chatpass_v2_scope_not_authorized", "chatpass_v2_invalid_authorization_context":
            return .configuration(code: code)
        case "subscription_sharing_invalid_user": return .unauthorized
        default: return nil
        }
    }
}
