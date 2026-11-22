import Foundation

/// The persistent registration: survives sign-out and terminal refresh errors.
public struct SIWCRegistration: Codable, Sendable, Equatable {
    /// `ext_agent_host_id`: `urn:uuid:<lowercased UUIDv4>`.
    public var hostID: String
    /// The issued `oaiapp_…` client id; nil until the first sign-in completes.
    public var clientID: String?

    public init(hostID: String, clientID: String?) {
        self.hostID = hostID
        self.clientID = clientID
    }
}

public struct SIWCTokens: Codable, Sendable, Equatable {
    public var idToken: String
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    public var earliestRefreshAt: Date?
    public var scopes: [String]
    public var subject: String
    public var email: String?

    public init(idToken: String, accessToken: String, refreshToken: String?, expiresAt: Date,
                earliestRefreshAt: Date?, scopes: [String], subject: String, email: String?) {
        self.idToken = idToken
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.earliestRefreshAt = earliestRefreshAt
        self.scopes = scopes
        self.subject = subject
        self.email = email
    }
}

/// Re-sign-in hints (`id_token_hint`, `login_hint`) kept after a terminal refresh error.
public struct SIWCHint: Codable, Sendable, Equatable {
    public var idToken: String
    public var email: String?

    public init(idToken: String, email: String?) {
        self.idToken = idToken
        self.email = email
    }
}

public struct SIWCAccount: Codable, Sendable, Equatable {
    public var registration: SIWCRegistration
    public var tokens: SIWCTokens?
    public var hint: SIWCHint?

    public init(registration: SIWCRegistration, tokens: SIWCTokens?, hint: SIWCHint?) {
        self.registration = registration
        self.tokens = tokens
        self.hint = hint
    }

    /// Plan usage needs the `chatgpt.tokens.use.direct` scope.
    public var planUsageEnabled: Bool { tokens?.scopes.contains(SIWC.requiredScope) == true }

    /// A new, unregistered account with a fresh host id.
    public static func fresh() -> SIWCAccount {
        SIWCAccount(registration: .init(hostID: "urn:uuid:\(UUID().uuidString.lowercased())", clientID: nil), tokens: nil, hint: nil)
    }
}

extension SIWCTokens: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private var redactedFields: KeyValuePairs<String, Any> {
        ["idToken": Redacted.secret(idToken), "accessToken": Redacted.secret(accessToken),
         "refreshToken": Redacted.secret(refreshToken), "expiresAt": expiresAt,
         "earliestRefreshAt": earliestRefreshAt as Any, "scopes": scopes,
         "subject": Redacted.secret(subject), "email": Redacted.secret(email)]
    }
    public var description: String { Redacted.describe("SIWCTokens", redactedFields) }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: redactedFields, displayStyle: .struct) }
}

extension SIWCHint: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private var redactedFields: KeyValuePairs<String, Any> {
        ["idToken": Redacted.secret(idToken), "email": Redacted.secret(email)]
    }
    public var description: String { Redacted.describe("SIWCHint", redactedFields) }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: redactedFields, displayStyle: .struct) }
}

extension SIWCAccount: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    // `tokens` and `hint` have redacting descriptions of their own.
    private var redactedFields: KeyValuePairs<String, Any> {
        ["registration": registration, "tokens": tokens as Any, "hint": hint as Any]
    }
    public var description: String { Redacted.describe("SIWCAccount", redactedFields) }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: redactedFields, displayStyle: .struct) }
}
