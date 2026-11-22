import Foundation

public struct TokenResponse: Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let idToken: String?
    public let expiresIn: Int
    public let scope: String?
    public let earliestRefreshAt: Date?

    public init(accessToken: String, refreshToken: String?, idToken: String?, expiresIn: Int, scope: String?, earliestRefreshAt: Date?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.expiresIn = expiresIn
        self.scope = scope
        self.earliestRefreshAt = earliestRefreshAt
    }

    /// Refresh errors that mean the session is gone and the user must sign in again.
    static let terminalRefreshCodes: Set<String> = [
        "invalid_grant", "invalid_refresh_token", "token_expired",
        "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused",
    ]

    /// Parses a token-endpoint response (authorization-code exchange or refresh).
    public static func parse(status: Int, body: Data) throws -> TokenResponse {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        if (200..<300).contains(status), let o = object, let access = o["access_token"] as? String, !access.isEmpty {
            return TokenResponse(
                accessToken: access,
                refreshToken: nonEmptyString(o["refresh_token"]),
                idToken: nonEmptyString(o["id_token"]),
                expiresIn: expiresIn(o["expires_in"]),
                scope: o["scope"] as? String,
                earliestRefreshAt: number(o["earliest_refresh_at"]).map { Date(timeIntervalSince1970: $0) })
        }
        let code = errorCode(object)
        if let code, terminalRefreshCodes.contains(code) { throw AuthError.terminalRefresh(code) }
        if code == "invalid_client" { throw AuthError.invalidClient }
        throw AuthError.tokenEndpoint(status: status, code: code)
    }

    /// Longest accepted `expires_in` (30 days).
    static let maxExpiresIn = 2_592_000

    /// `expires_in` from remote input: whole seconds in `1...maxExpiresIn`. Anything else (missing,
    /// non-numeric, zero, negative, fractional overflow, absurdly large) falls back to the documented
    /// 3600 s rather than trapping or trusting it; a too-long value would only delay the refresh.
    private static func expiresIn(_ v: Any?) -> Int {
        guard let d = number(v)?.rounded(.down), let seconds = Int(exactly: d), (1...maxExpiresIn).contains(seconds) else {
            return 3600
        }
        return seconds
    }

    private static func errorCode(_ o: [String: Any]?) -> String? {
        switch o?["error"] {
        case let s as String: return s
        case let e as [String: Any]: return e["code"] as? String
        default: return nil
        }
    }

    private static func nonEmptyString(_ v: Any?) -> String? {
        guard let s = v as? String, !s.isEmpty else { return nil }
        return s
    }

    /// A JSON number, or a string holding one (`earliest_refresh_at` arrives as either).
    private static func number(_ v: Any?) -> Double? {
        switch v {
        case let n as NSNumber where CFGetTypeID(n) != CFBooleanGetTypeID():
            return n.doubleValue.isFinite ? n.doubleValue : nil
        case let s as String:
            return Double(s.trimmingCharacters(in: .whitespaces)).flatMap { $0.isFinite ? $0 : nil }
        default:
            return nil
        }
    }
}

extension TokenResponse: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private var redactedFields: KeyValuePairs<String, Any> {
        ["accessToken": Redacted.secret(accessToken), "refreshToken": Redacted.secret(refreshToken),
         "idToken": Redacted.secret(idToken), "expiresIn": expiresIn, "scope": scope as Any,
         "earliestRefreshAt": earliestRefreshAt as Any]
    }
    public var description: String { Redacted.describe("TokenResponse", redactedFields) }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: redactedFields, displayStyle: .struct) }
}
