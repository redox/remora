import Foundation
import Storage

public enum LLMError: Error, Sendable, Equatable {
    case notSignedIn, needsSignIn, planUsageDisabled, usageLimit
    case temporarilyUnavailable(code: String?)
    case notEligible
    case unsupported(param: String?)
    case configuration(code: String)
    case unauthorized, forbidden
    case badRequest(code: String?, param: String?)
    case http(status: Int)
    case transport(code: Int)
    case incomplete(reason: String?)
    case streamEndedEarly
    case onDeviceUnavailable(reason: String)
    case schemaMismatch
    case forbiddenField(String)
    case cancelled

    public var callStatus: LLMCallStatus {
        switch self {
        case .usageLimit: return .limit
        case .cancelled: return .cancelled
        default: return .failed
        }
    }

    /// Stable string for `llm_calls.error_code`.
    public var errorCode: String? {
        switch self {
        case .notSignedIn: return "not_signed_in"
        case .needsSignIn: return "needs_sign_in"
        case .planUsageDisabled: return "plan_usage_disabled"
        case .usageLimit: return "usage_limit"
        case .temporarilyUnavailable(let c): return c ?? "temporarily_unavailable"
        case .notEligible: return "not_eligible"
        case .unsupported: return "unsupported"
        case .configuration(let c): return c
        case .unauthorized: return "unauthorized"
        case .forbidden: return "forbidden"
        case .badRequest(let c, _): return c ?? "bad_request"
        case .http(let s): return "http_\(s)"
        case .transport(let c): return "transport_\(c)"
        case .incomplete(let r): return r.map { "incomplete_\($0)" } ?? "incomplete"
        case .streamEndedEarly: return "stream_ended_early"
        case .onDeviceUnavailable: return "on_device_unavailable"
        case .schemaMismatch: return "schema_mismatch"
        case .forbiddenField: return "forbidden_field"
        case .cancelled: return "cancelled"
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .temporarilyUnavailable, .transport: return true
        case .http(let s): return (500..<600).contains(s)
        default: return false
        }
    }
}
