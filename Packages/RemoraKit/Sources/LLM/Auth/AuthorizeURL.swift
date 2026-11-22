import Foundation

/// One sign-in attempt: everything the callback handler and the code exchange need.
public struct AuthAttempt: Sendable {
    public let state: String
    public let nonce: String
    public let pkce: PKCE
    public let redirectURI: String
    public let clientID: String
    /// Contains `id_token_hint` on re-sign-in: never log it.
    public let url: URL
}

extension AuthAttempt: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private var redactedFields: KeyValuePairs<String, Any> {
        ["state": Redacted.secret(state), "nonce": Redacted.secret(nonce), "pkce": pkce,
         "redirectURI": redirectURI, "clientID": clientID, "url": Redacted.secret(url.absoluteString)]
    }
    public var description: String { Redacted.describe("AuthAttempt", redactedFields) }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: redactedFields, displayStyle: .struct) }
}

public enum AuthorizeURL {
    public static func make(port: UInt16, account: SIWCAccount, state: String, nonce: String, pkce: PKCE) -> AuthAttempt {
        let issuedClientID = account.registration.clientID
        let clientID = issuedClientID ?? SIWC.dynamicClientID
        let redirect = "http://127.0.0.1:\(port)\(SIWC.callbackPath)"
        var pairs: [(String, String)] = [
            ("response_type", "code"),
            ("client_id", clientID),
            ("redirect_uri", redirect),
            ("scope", SIWC.scopes.joined(separator: " ")),
            ("resource", SIWC.apiBase),
            ("state", state),
            ("nonce", nonce),
            ("code_challenge", pkce.challenge),
            ("code_challenge_method", "S256"),
            ("ext_agent_host_id", account.registration.hostID),
        ]
        if issuedClientID == nil {
            pairs.append(("agent_name_hint", SIWC.agentName))
        } else if let hint = account.hint {
            if !hint.idToken.isEmpty { pairs.append(("id_token_hint", hint.idToken)) }
            if let email = hint.email, !email.isEmpty { pairs.append(("login_hint", email)) }
        }
        let url = URL(string: "\(SIWC.authorizeURL.absoluteString)?\(FormEncoding.encode(pairs))")!
        return AuthAttempt(state: state, nonce: nonce, pkce: pkce, redirectURI: redirect, clientID: clientID, url: url)
    }
}

/// `application/x-www-form-urlencoded` / query encoding: only RFC 3986 unreserved characters pass through.
enum FormEncoding {
    private static let unreserved: CharacterSet = {
        var c = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        c.insert(charactersIn: "-._~")
        return c
    }()

    static func encode(_ pairs: [(String, String)]) -> String {
        pairs.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
    }

    private static func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }
}
