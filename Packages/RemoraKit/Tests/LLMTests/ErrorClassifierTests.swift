import Testing
import Foundation
@testable import LLM

@Test(arguments: [
    (429, #"{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}"#, LLMError.usageLimit),
    (503, #"{"error":{"code":"subscription_sharing_usage_unavailable"}}"#, LLMError.temporarilyUnavailable(code: "subscription_sharing_usage_unavailable")),
    (503, #"{"error":{"code":"subscription_sharing_user_unavailable"}}"#, LLMError.temporarilyUnavailable(code: "subscription_sharing_user_unavailable")),
    (403, #"{"error":{"code":"subscription_sharing_user_not_eligible"}}"#, LLMError.notEligible),
    (400, #"{"error":{"code":"subscription_sharing_unsupported_capability","param":"tools"}}"#, LLMError.unsupported(param: "tools")),
    (403, #"{"error":{"code":"subscription_sharing_route_not_supported"}}"#, LLMError.configuration(code: "subscription_sharing_route_not_supported")),
    (403, #"{"error":{"code":"chatpass_v2_scope_not_authorized"}}"#, LLMError.configuration(code: "chatpass_v2_scope_not_authorized")),
    (403, #"{"error":{"code":"chatpass_v2_invalid_authorization_context"}}"#, LLMError.configuration(code: "chatpass_v2_invalid_authorization_context")),
    (401, #"{"error":{"code":"subscription_sharing_invalid_user"}}"#, LLMError.unauthorized),
    (401, #"{"detail":"Unauthorized"}"#, LLMError.unauthorized),
    (403, #"{"detail":"blocked"}"#, LLMError.forbidden),
    (429, #"{"detail":"slow"}"#, LLMError.usageLimit),
    // A 429 is the plan's usage limit only with a subscription usage code or no code at all.
    (429, #"{"error":{"code":"subscription_sharing_usage_exhausted"}}"#, LLMError.usageLimit),
    (429, #"{"error":{"code":"rate_limit_exceeded"}}"#, LLMError.temporarilyUnavailable(code: "rate_limit_exceeded")),
    (429, #"{"error":{"message":"slow down"}}"#, LLMError.usageLimit),
    (503, #"{"detail":"x"}"#, LLMError.temporarilyUnavailable(code: nil)),
    (422, #"{"error":{"code":"weird","param":"p"}}"#, LLMError.badRequest(code: "weird", param: "p")),
    (500, "<html>", LLMError.http(status: 500)),
])
func classifies(status: Int, body: String, expected: LLMError) {
    #expect(ErrorClassifier.classify(status: status, body: Data(body.utf8)) == expected)
}

@Test func classifiesByCode() {
    #expect(ErrorClassifier.classify(code: "subscription_sharing_usage_limit_exceeded", param: nil) == .usageLimit)
    #expect(ErrorClassifier.classify(code: nil, param: nil) == .temporarilyUnavailable(code: nil))
}

@Test(arguments: ["server_error", "rate_limit_exceeded"])
func unknownMidStreamCodesAreRetryable(code: String) {
    let e = ErrorClassifier.classify(code: code, param: nil)
    #expect(e == .temporarilyUnavailable(code: code) && e.isRetryable)
}

@Test func serverCodesAreTruncatedTo64Characters() {
    let long = String(repeating: "x", count: 200)
    #expect(ErrorClassifier.classify(code: long, param: nil) == .temporarilyUnavailable(code: String(repeating: "x", count: 64)))
    let body = Data(#"{"error":{"code":"\#(long)","param":"\#(long)"}}"#.utf8)
    let want = String(repeating: "x", count: 64)
    #expect(ErrorClassifier.classify(status: 422, body: body) == .badRequest(code: want, param: want))
    #expect(ErrorClassifier.classify(status: 503, body: body) == .temporarilyUnavailable(code: want))
}

@Test func rateLimited429IsRetryable() {
    #expect(ErrorClassifier.classify(status: 429, body: Data(#"{"error":{"code":"rate_limit_exceeded"}}"#.utf8)).isRetryable)
}
