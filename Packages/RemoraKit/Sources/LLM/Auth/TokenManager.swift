import Foundation
import os

/// Owns the signed-in session and is the **only writer** of the credential store: sign-in, refresh
/// and sign-out all save through this actor, so a refresh can never overwrite a newer sign-in.
///
/// - Refreshes are serialized: concurrent callers (forced or not) await the one in-flight refresh.
/// - As soon as the token endpoint answers, the rotated access + refresh tokens are saved (with the
///   old ID token, email and `sub`), before the new ID token is even validated. After validation the
///   new ID token and email are saved too. Nothing is handed out before it is persisted: if a save
///   fails, the tokens stay in memory, the call throws, and the next call saves them first.
/// - Only an identity failure of the refresh ID token ends the session: another `sub`, wrong `aud` or
///   `iss`, a disallowed `alg`, a bad signature against a key we hold, or an undecodable token. A JWKS
///   that cannot be reached (or lacks the `kid`) or an `exp`/`iat` failure (clock skew) is not one: the
///   payload's `sub` is compared unverified (the token arrived over TLS from the token endpoint, OIDC
///   Core §3.1.3.7(6)); a match keeps the rotated tokens with the old ID token.
/// - A terminal refresh error (`terminalRefresh` codes, `invalid_client`) or an identity failure moves
///   the old ID token and email into `hint`, clears `tokens` and keeps the registration (host id +
///   issued client id; `invalid_client` also forgets the client id so the next sign-in re-registers).
/// - Transient failures (transport, 5xx, any other token-endpoint error) keep the credentials and fall
///   back to the current access token while it is still valid.
public actor TokenManager {
    private let store: any CredentialStore
    private let http: any HTTPTransport
    private let validator: IDTokenValidator
    private let now: @Sendable () -> Date

    private var account: SIWCAccount?
    private var loaded = false
    /// The in-memory account differs from the store (a save failed).
    private var unsaved = false
    /// Bumped by sign-in and sign-out, so a refresh that straddles one is discarded.
    private var generation = 0
    private var inFlight: Task<String, any Error>?

    private static let log = Logger(subsystem: "dev.remora", category: "auth")

    public init(store: any CredentialStore, http: any HTTPTransport, validator: IDTokenValidator,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.http = http
        self.validator = validator
        self.now = now
    }

    // MARK: - Public API

    public func state() -> SignInState {
        let a: SIWCAccount?
        do { a = try loadedAccount() } catch { return .unavailable }
        guard let a else { return .signedOut }
        if let t = a.tokens {
            return a.registration.clientID == nil ? .needsSignIn : .signedIn(email: t.email, planUsageEnabled: a.planUsageEnabled)
        }
        return a.hint != nil ? .needsSignIn : .signedOut
    }

    /// A usable access token, refreshed first when due (or when `forceRefresh`).
    /// Throws `LLMError.notSignedIn`, `.needsSignIn`, `.planUsageDisabled` or `.temporarilyUnavailable`.
    public func accessToken(forceRefresh: Bool = false) async throws -> String {
        let tokens = try usableForRequests()
        if !forceRefresh, inFlight == nil, !RefreshPolicy.isDue(tokens, now: now()) { return tokens.accessToken }
        return try await refresh()
    }

    /// After a 401: refreshes only if `rejected` is still the current access token. If another caller
    /// already replaced it (or a refresh is in flight), that token is used instead of refreshing again.
    public func forceRefresh(rejected: String) async throws -> String {
        let tokens = try usableForRequests()
        if inFlight == nil, tokens.accessToken != rejected {
            return try await accessToken()
        }
        return try await refresh()
    }

    /// Proactive refresh (launch, timer, wake). Errors are absorbed; `state()` reflects the outcome.
    public func refreshIfDue() async {
        try? persistIfNeeded()
        guard let a = try? loadedAccount(), let tokens = try? usableTokens(a), RefreshPolicy.isDue(tokens, now: now()) else { return }
        _ = try? await refresh()
    }

    /// Drops the tokens and the re-sign-in hint, keeps the registration. There is no revocation
    /// endpoint to call.
    public func signOut() throws {
        guard var a = try loadedAccount() else { return }
        a.tokens = nil
        a.hint = nil
        try replaceAccount(a)
        Self.log.info("signed out")
    }

    /// Advanced: signs out and also forgets the registration (host id and issued client id), so the
    /// next sign-in registers this Mac again. Deletes the stored credential; any refresh in flight is
    /// discarded.
    public func forgetRegistration() throws {
        try store.delete()
        account = nil
        loaded = true
        unsaved = false
        generation += 1
        inFlight = nil
        Self.log.info("registration forgotten")
    }

    /// Saves the account `SignInFlow` produced and makes it current; any refresh still in flight is
    /// discarded.
    public func didSignIn(_ a: SIWCAccount) throws {
        try replaceAccount(a)
    }

    /// The stored account (nil if none). Throws `.temporarilyUnavailable("credential_store")`.
    func currentAccount() throws -> SIWCAccount? {
        try loadedAccount()
    }

    /// Persists `a` and makes it current (sign-in, sign-out, registration changes). Memory is only
    /// updated once the save succeeded.
    func replaceAccount(_ a: SIWCAccount) throws {
        try store.save(a)
        account = a
        loaded = true
        unsaved = false
        generation += 1
        inFlight = nil
    }

    // MARK: - Account

    private func loadedAccount() throws -> SIWCAccount? {
        if !loaded {
            do {
                account = try store.load()
                loaded = true
            } catch {
                Self.log.error("credential store load failed")
                throw LLMError.temporarilyUnavailable(code: "credential_store")
            }
        }
        return account
    }

    private func usableTokens(_ a: SIWCAccount?) throws -> SIWCTokens {
        guard let a, let tokens = a.tokens, a.registration.clientID != nil else {
            throw (a?.hint != nil || a?.tokens != nil) ? LLMError.needsSignIn : LLMError.notSignedIn
        }
        return tokens
    }

    private func usableForRequests() throws -> SIWCTokens {
        try persistIfNeeded()
        let a = try loadedAccount()
        let tokens = try usableTokens(a)
        guard a?.planUsageEnabled == true else { throw LLMError.planUsageDisabled }
        return tokens
    }

    private func persistIfNeeded() throws {
        guard unsaved, let account else { return }
        do {
            try store.save(account)
            unsaved = false
        } catch {
            Self.log.error("credential store save failed")
            throw LLMError.temporarilyUnavailable(code: "credential_store")
        }
    }

    /// Updates memory, then the store; a failed save is retried before the next token is handed out.
    private func commit(_ a: SIWCAccount) throws {
        account = a
        unsaved = true
        try persistIfNeeded()
    }

    // MARK: - Refresh

    private func refresh() async throws -> String {
        if let inFlight { return try await inFlight.value }
        // Unstructured on purpose: a cancelled caller must not abandon a rotation half-way.
        let task = Task { try await self.performRefresh() }
        inFlight = task
        return try await task.value
    }

    private func performRefresh() async throws -> String {
        let gen = generation
        defer { if gen == generation { inFlight = nil } }
        let current = try loadedAccount()
        let old = try usableTokens(current)
        guard var a = current, let clientID = a.registration.clientID else { throw LLMError.notSignedIn }
        guard let refreshToken = old.refreshToken else {
            if old.expiresAt > now() { return old.accessToken }
            Self.log.error("token refresh: no refresh token")
            endSession(a, forgetClient: false)
            throw LLMError.needsSignIn
        }

        let response: TokenResponse
        do {
            response = try await post(clientID: clientID, refreshToken: refreshToken)
        } catch let error as AuthError where Self.isTerminal(error) {
            guard gen == generation else { return try superseded() }
            Self.log.error("token refresh: session ended (\(SignInFlow.kind(error), privacy: .public))")
            endSession(a, forgetClient: error == .invalidClient)
            throw LLMError.needsSignIn
        } catch {
            guard gen == generation else { return try superseded() }
            Self.log.error("token refresh: transient failure (\(SignInFlow.kind(error), privacy: .public))")
            if old.expiresAt > now() { return old.accessToken }
            throw LLMError.temporarilyUnavailable(code: nil)
        }
        guard gen == generation else { return try superseded() }

        // 1. Persist the rotation at once (old ID token, email and sub), before any further await.
        a.tokens = SIWCTokens(
            idToken: old.idToken, accessToken: response.accessToken, refreshToken: response.refreshToken ?? refreshToken,
            expiresAt: now().addingTimeInterval(TimeInterval(response.expiresIn)),
            earliestRefreshAt: response.earliestRefreshAt,
            scopes: response.scope.map { $0.split(separator: " ").map(String.init) } ?? old.scopes,
            subject: old.subject, email: old.email)
        try? commit(a)  // on failure `unsaved` stays set; the final commit below retries and throws

        // 2. Validate the new ID token, if any, and adopt it.
        if let newID = response.idToken {
            let outcome = await check(newID, clientID: clientID, subject: old.subject)
            guard gen == generation else { return try superseded() }
            switch outcome {
            case .verified(let email):
                a.tokens?.idToken = newID
                a.tokens?.email = email ?? old.email
            case .sameSubjectUnverified:
                break  // keep the old ID token alongside the rotated tokens
            case .identityFailure(let reason):
                Self.log.error("token refresh: ID token rejected (\(reason, privacy: .public))")
                endSession(a, forgetClient: false)
                throw LLMError.needsSignIn
            }
        }
        try commit(a)  // persisted before the new access token leaves this actor
        Self.log.info("token refresh: ok (rotated \(response.refreshToken != nil, privacy: .public))")
        return response.accessToken
    }

    private enum IDTokenOutcome {
        case verified(email: String?)
        case sameSubjectUnverified
        case identityFailure(String)
    }

    /// Classifies a refresh-time ID token (`nonce` is nil at refresh).
    private func check(_ jwt: String, clientID: String, subject: String) async -> IDTokenOutcome {
        do {
            let claims = try await validator.validate(jwt, clientID: clientID, nonce: nil)
            guard claims.subject == subject else { return .identityFailure("identityMismatch") }
            return .verified(email: claims.email)
        } catch {
            guard Self.isVerificationUnavailable(error) else { return .identityFailure(SignInFlow.kind(error)) }
            // Keys unreachable or clock skew: fall back to the unverified `sub` from a TLS-delivered token.
            guard let sub = IDTokenValidator.unverifiedSubject(jwt), sub == subject else {
                return .identityFailure("identityMismatch.unverified")
            }
            Self.log.error("token refresh: ID token not verifiable (\(SignInFlow.kind(error), privacy: .public)); same subject, kept")
            return .sameSubjectUnverified
        }
    }

    /// Failures that say nothing about whose token it is: JWKS unreachable or missing the `kid`, an
    /// unusable key, or `exp`/`iat` out of range on our clock.
    private static func isVerificationUnavailable(_ error: any Error) -> Bool {
        guard let e = error as? AuthError else { return true }  // transport errors from the JWKS fetch
        if case .idToken(let check) = e { return ["jwks", "kid", "key", "exp", "iat"].contains(check) }
        return false
    }

    private func post(clientID: String, refreshToken: String) async throws -> TokenResponse {
        var request = URLRequest(url: SIWC.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // No `scope`: a refresh keeps the granted scopes.
        request.httpBody = Data(FormEncoding.encode([
            ("grant_type", "refresh_token"),
            ("client_id", clientID),
            ("refresh_token", refreshToken),
            ("resource", SIWC.apiBase),
        ]).utf8)
        let (body, response) = try await http.data(for: request)
        return try TokenResponse.parse(status: response.statusCode, body: body)
    }

    private static func isTerminal(_ e: AuthError) -> Bool {
        switch e {
        case .terminalRefresh, .invalidClient: return true
        default: return false
        }
    }

    /// Ends the session but keeps the registration (and, unless told otherwise, the client id).
    private func endSession(_ a: SIWCAccount, forgetClient: Bool) {
        var ended = a
        if let t = a.tokens { ended.hint = SIWCHint(idToken: t.idToken, email: t.email) }
        ended.tokens = nil
        if forgetClient { ended.registration.clientID = nil }
        try? commit(ended)
    }

    /// A sign-in or sign-out happened during the refresh: its result is dropped.
    private func superseded() throws -> String {
        let a = account
        if let t = a?.tokens, a?.registration.clientID != nil { return t.accessToken }
        throw a?.hint != nil ? LLMError.needsSignIn : LLMError.notSignedIn
    }
}
