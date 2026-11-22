import Foundation
import os

public protocol BrowserOpening: Sendable {
    /// Opens `url` in the system browser; false if it could not be opened.
    func open(_ url: URL) -> Bool
}

/// One "Continue with ChatGPT" attempt: loopback listener, system browser, callback checks, code
/// exchange, ID-token validation, then the account is saved.
///
/// Callback checks run in this order, before any network call: `state` (always first), the OAuth
/// `error`, `iss`, `code`, then the client id. On a first registration the ID token's audience is the
/// `client_id` issued in the callback. On re-sign-in the callback usually omits `client_id`; the retained
/// id is used and a callback carrying a different one is rejected.
///
/// Every read and write of the account goes through `TokenManager` (the single writer), so a refresh
/// racing with the sign-in can never overwrite it.
public struct SignInFlow: Sendable {
    private let tokens: TokenManager
    private let http: any HTTPTransport
    private let validator: IDTokenValidator
    private let browser: any BrowserOpening
    private let server: @Sendable () -> LoopbackServer
    private let callbackTimeout: Duration
    private let now: @Sendable () -> Date

    private static let log = Logger(subsystem: "dev.remora", category: "auth")

    public init(tokens: TokenManager, http: any HTTPTransport, validator: IDTokenValidator, browser: any BrowserOpening,
                server: @escaping @Sendable () -> LoopbackServer = { LoopbackServer() },
                callbackTimeout: Duration = SIWC.callbackTimeout, now: @escaping @Sendable () -> Date = Date.init) {
        self.tokens = tokens
        self.http = http
        self.validator = validator
        self.browser = browser
        self.server = server
        self.callbackTimeout = callbackTimeout
        self.now = now
    }

    /// Returns the saved account (already adopted by the `TokenManager`). Errors are `AuthError`s,
    /// transport errors, `CancellationError` (the calling task was cancelled), or store errors.
    public func signIn() async throws -> SIWCAccount {
        var account: SIWCAccount
        if let existing = try await tokens.currentAccount() {
            account = existing
        } else {
            // Persist the host id before the browser can register an agent under it.
            account = .fresh()
            try await tokens.replaceAccount(account)
        }

        let listener = server()
        defer { listener.stop() }
        let port = try await listener.start()
        let attempt = AuthorizeURL.make(port: port, account: account, state: RandomToken.make(), nonce: RandomToken.make(), pkce: .make())
        guard browser.open(attempt.url) else {
            Self.log.error("sign-in: browser could not be opened")
            throw AuthError.browserUnavailable
        }
        let callback = try await listener.waitForCallback(timeout: callbackTimeout)
        do {
            let signedIn = try await complete(callback, attempt: attempt, account: &account)
            listener.finish(signedIn: true)
            Self.log.info("sign-in: succeeded (plan usage \(signedIn.planUsageEnabled ? "enabled" : "missing", privacy: .public))")
            return signedIn
        } catch {
            listener.finish(signedIn: false)
            Self.log.error("sign-in: failed (\(Self.kind(error), privacy: .public))")
            throw error
        }
    }

    private func complete(_ q: [String: String], attempt: AuthAttempt, account: inout SIWCAccount) async throws -> SIWCAccount {
        // 1. State first: nothing else in an unverified callback is trusted.
        guard let state = q["state"], Self.constantTimeEqual(state, attempt.state) else { throw AuthError.stateMismatch }
        // 2. The authorization server's verdict.
        if let error = q["error"] {
            throw error == "access_denied" ? AuthError.accessDenied : AuthError.authorizationFailed(error)
        }
        // RFC 9207: the issuer identifies the authorization server; it is always sent, so require it.
        guard q["iss"] == SIWC.issuer else { throw AuthError.issuerMismatch }
        guard let code = q["code"], !code.isEmpty else { throw AuthError.authorizationFailed(nil) }

        // 3. Which client this sign-in belongs to.
        let retained = account.registration.clientID
        let clientID: String
        if let retained {
            if let c = q["client_id"], c != retained { throw AuthError.clientIDMismatch }
            clientID = retained
        } else {
            guard let issued = q["client_id"], !issued.isEmpty, issued != SIWC.dynamicClientID else {
                throw AuthError.registrationIncomplete
            }
            clientID = issued
        }

        // 4. Code exchange.
        let response: TokenResponse
        do {
            response = try await exchange(code: code, clientID: clientID, attempt: attempt)
        } catch AuthError.invalidClient {
            if retained != nil {
                // The retained client is gone: forget it (and its tokens) so the next attempt re-registers.
                account.registration.clientID = nil
                account.tokens = nil
                account.hint = nil
                try await tokens.replaceAccount(account)
            }
            throw AuthError.invalidClient
        }

        // 5. ID token: signature, iss, aud (this client id), exp, iat, nonce (this attempt), sub.
        guard let idToken = response.idToken else { throw AuthError.missingIDToken }
        let claims = try await validator.validate(idToken, clientID: clientID, nonce: attempt.nonce)
        // The session may have changed (a refresh, a sign-out) while the browser was open: re-read it.
        account = try await tokens.currentAccount() ?? account
        if let current = account.tokens, current.subject != claims.subject {
            // Still signed in as someone else: switching accounts needs a sign-out first.
            throw AuthError.identityMismatch
        }

        // 6. Save. A missing `chatgpt.tokens.use.direct` scope still saves; plan usage is then off.
        // No `scope` in the response or the callback means the requested scopes were granted (RFC 6749 §5.1).
        let scopes = (response.scope ?? q["scope"]).map { $0.split(separator: " ").map(String.init) } ?? SIWC.scopes
        account.registration.clientID = clientID
        account.tokens = SIWCTokens(
            idToken: idToken, accessToken: response.accessToken, refreshToken: response.refreshToken,
            expiresAt: now().addingTimeInterval(TimeInterval(response.expiresIn)),
            earliestRefreshAt: response.earliestRefreshAt, scopes: scopes, subject: claims.subject, email: claims.email)
        account.hint = nil
        try await tokens.didSignIn(account)
        return account
    }

    private func exchange(code: String, clientID: String, attempt: AuthAttempt) async throws -> TokenResponse {
        var request = URLRequest(url: SIWC.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(FormEncoding.encode([
            ("grant_type", "authorization_code"),
            ("client_id", clientID),
            ("code", code),
            ("code_verifier", attempt.pkce.verifier),
            ("redirect_uri", attempt.redirectURI),
            ("resource", SIWC.apiBase),
        ]).utf8)
        let (body, response) = try await http.data(for: request)
        do {
            return try TokenResponse.parse(status: response.statusCode, body: body)
        } catch AuthError.terminalRefresh(let code) {
            // `invalid_grant` here means this code was refused: a failed sign-in, not an expired session.
            throw AuthError.tokenEndpoint(status: response.statusCode, code: code)
        }
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// A log-safe name for an error: the case, never values from the callback or tokens.
    static func kind(_ error: any Error) -> String {
        switch error {
        case let e as AuthError:
            switch e {
            case .idToken(let check): return "idToken.\(check)"
            case .tokenEndpoint(let status, let code): return "tokenEndpoint.\(status).\(code.map(short) ?? "-")"
            case .authorizationFailed(let code): return "authorizationFailed.\(code.map(short) ?? "missing_code")"
            case .terminalRefresh(let code): return "terminalRefresh.\(short(code))"
            default: return "\(e)"
            }
        case is CancellationError: return "cancelled"
        case let e as URLError: return "transport.\(e.code.rawValue)"
        default: return String(describing: type(of: error))
        }
    }

    /// Server error codes are short identifiers; cap whatever arrives.
    private static func short(_ code: String) -> String { String(code.prefix(64)) }
}
