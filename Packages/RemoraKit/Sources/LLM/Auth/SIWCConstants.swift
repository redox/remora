import Foundation

/// Sign in with ChatGPT constants, exactly as proven by the spike (docs/research/siwc-spike.md).
public enum SIWC {
    public static let authorizeURL = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    public static let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    public static let issuer = "https://auth.openai.com"
    public static let jwksURL = URL(string: "https://auth.openai.com/.well-known/jwks.json")!
    /// API base, also sent as the OAuth `resource` parameter.
    public static let apiBase = "https://api.openai.com/v1"
    public static let dynamicClientID = "dynamic_agent_client"
    public static let agentName = "Remora"
    public static let scopes = ["openid", "profile", "email", "offline_access", "resource.invoke", "chatgpt.tokens.use.direct"]
    public static let requiredScope = "chatgpt.tokens.use.direct"
    public static let callbackPath = "/auth/callback"
    public static let ports: [UInt16] = [1455, 1456, 1457, 1458, 1459]
    public static let callbackTimeout: Duration = .seconds(600)
    public static let usageSettingsURL = URL(string: "https://chatgpt.com/settings/usage")!
}

public enum AuthError: Error, Sendable, Equatable {
    case stateMismatch, accessDenied, registrationIncomplete, clientIDMismatch, missingIDToken
    /// ID-token validation failed; the payload names the failed check (never token contents).
    case idToken(String)
    case missingRequiredScope
    case terminalRefresh(String)
    case invalidClient
    case tokenEndpoint(status: Int, code: String?)
    case listenerFailed, timedOut, identityMismatch
    /// The system browser could not be opened for the authorize URL.
    case browserUnavailable
    /// The callback's `iss` parameter is not `SIWC.issuer`.
    case issuerMismatch
    /// The callback carried an OAuth `error` other than `access_denied` (the code), or no `code` (nil).
    case authorizationFailed(String?)
}

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Strict base64url: the standard alphabet's `+` and `/` and any `=` padding are rejected.
    static func decode(_ string: some StringProtocol) -> Data? {
        guard !string.contains(where: { $0 == "+" || $0 == "/" || $0 == "=" }) else { return nil }
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        switch s.count % 4 {
        case 0: break
        case 2: s += "=="
        case 3: s += "="
        default: return nil
        }
        return Data(base64Encoded: s)
    }
}

/// Builds descriptions and mirrors for types that carry tokens, codes, verifiers or account
/// identifiers, so `print`, `dump`, string interpolation and test-failure output never show them.
enum Redacted {
    static func secret(_ value: String?) -> String { value == nil ? "nil" : "<redacted>" }

    static func describe(_ type: String, _ fields: KeyValuePairs<String, Any>) -> String {
        "\(type)(" + fields.map { "\($0.key): \(describeValue($0.value))" }.joined(separator: ", ") + ")"
    }

    /// Unwraps optionals so fields read `nil` / the value instead of `Optional(...)`.
    private static func describeValue(_ value: Any) -> String {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else { return String(describing: value) }
        return mirror.children.first.map { String(describing: $0.value) } ?? "nil"
    }
}
