import Foundation
import LLMTestSupport
import Synchronization
import Testing
@testable import LLM

// MARK: - Refresh policy

@Test(arguments: [(3000.0, false), (3240.0, true), (3550.0, true)])  // issued at 0, expires 3600, earliest 3240
func refreshDue(now: Double, due: Bool) {
    #expect(RefreshPolicy.isDue(.fixture(expiresAt: 3600, earliest: 3240), now: Date(timeIntervalSince1970: now)) == due)
}

@Test(arguments: [(3299.0, false), (3300.0, true)])
func refreshDueWithoutEarliestIsFiveMinutesBeforeExpiry(now: Double, due: Bool) {
    #expect(RefreshPolicy.isDue(.fixture(expiresAt: 3600, earliest: nil), now: Date(timeIntervalSince1970: now)) == due)
}

@Test(arguments: [(3539.0, false), (3540.0, true)])
func lateEarliestIsCappedAtOneMinuteBeforeExpiry(now: Double, due: Bool) {
    #expect(RefreshPolicy.isDue(.fixture(expiresAt: 3600, earliest: 3590), now: Date(timeIntervalSince1970: now)) == due)
}

// MARK: - Token manager

/// The clock: `now` is Fx.t0; tokens expiring at t0 + `expiresIn` with `earliest` at t0 + `earliestIn`.
private func signedIn(expiresIn: Double, earliestIn: Double? = nil, scopes: [String] = SIWC.scopes,
                      refresh: String? = "rt-1") -> SIWCAccount {
    Fx.account(tokens: Fx.tokens(refresh: refresh, idToken: "id-old", expiresAt: Fx.t0.addingTimeInterval(expiresIn),
                                 earliest: earliestIn.map { Fx.t0.addingTimeInterval($0) }, scopes: scopes))
}

private func manager(_ store: any CredentialStore, _ fake: FakeHTTPTransport, jwks: FxJWKS = FxJWKS()) -> TokenManager {
    TokenManager(store: store, http: fake, validator: Fx.validator(jwks: jwks), now: { Fx.t0 })
}

private func llmError(_ body: () async throws -> String) async -> LLMError? {
    do { _ = try await body(); return nil } catch let e as LLMError { return e } catch { return .http(status: -1) }
}

@Test func notDueReturnsStoredTokenWithoutNetwork() async throws {
    let fake = FakeHTTPTransport()
    let m = manager(InMemoryCredentialStore(signedIn(expiresIn: 3000)), fake)
    #expect(try await m.accessToken() == "at-1" && fake.requests.isEmpty)
    #expect(await m.state() == .signedIn(email: "a@b.c", planUsageEnabled: true))
}

@Test func concurrentCallersShareOneRefresh() async throws {
    let store = InMemoryCredentialStore(signedIn(expiresIn: 30))  // due
    let fake = FakeHTTPTransport()
    fake.handle(Fx.tokenPath) { _ in
        try await Task.sleep(for: .milliseconds(100))
        return Fx.tokenResponse(access: "at-2", refresh: "rt-2", id: Fx.idToken())
    }
    let m = manager(store, fake)
    let tokens = try await withThrowingTaskGroup(of: String.self) { g in
        for _ in 0..<5 { g.addTask { try await m.accessToken() } }
        return try await g.reduce(into: [String]()) { $0.append($1) }
    }
    #expect(tokens == Array(repeating: "at-2", count: 5))
    #expect(fake.requests(to: Fx.tokenPath).count == 1)
    // The new token is not due: no further refresh.
    #expect(try await m.accessToken() == "at-2" && fake.requests.count == 1)
}

@Test func rotatedTokenPersistedBeforeUse() async throws {
    let store = SpyStore(signedIn(expiresIn: 30, earliestIn: 0))
    let fake = FakeHTTPTransport()
    fake.enqueue(Fx.tokenPath, Fx.tokenResponse(access: "at-2", refresh: "rt-2", id: Fx.idToken(email: "new@b.c"),
                                                scope: "openid chatgpt.tokens.use.direct", expiresIn: 3600,
                                                earliest: Fx.t0.timeIntervalSince1970 + 3240))
    let m = manager(store, fake)
    let token = try await m.accessToken()
    #expect(token == "at-2")
    // By the time the new access token is handed out, the whole replacement is in the store
    // (first the rotation, then the validated ID token and email).
    #expect(store.saves.count == 2 && store.saves[0].tokens?.refreshToken == "rt-2" && store.saves[0].tokens?.idToken == "id-old")
    let saved = try #require(store.stored?.tokens)
    #expect(saved.accessToken == "at-2" && saved.refreshToken == "rt-2" && saved.idToken != "id-old")
    #expect(saved.expiresAt == Fx.t0.addingTimeInterval(3600) && saved.earliestRefreshAt == Fx.t0.addingTimeInterval(3240))
    #expect(saved.scopes == ["openid", "chatgpt.tokens.use.direct"] && saved.email == "new@b.c" && saved.subject == "user-1")
    #expect(store.stored?.registration.clientID == "oaiapp_1")

    let r = fake.requests[0]
    #expect(r.url == SIWC.tokenURL && r.httpMethod == "POST")
    #expect(r.formBody == ["grant_type": "refresh_token", "client_id": "oaiapp_1", "refresh_token": "rt-1",
                           "resource": "https://api.openai.com/v1"])
}

@Test func refreshWithoutRotationOrIDTokenKeepsThem() async throws {
    let store = SpyStore(signedIn(expiresIn: 30, earliestIn: 0))
    let fake = FakeHTTPTransport()
    fake.enqueue(Fx.tokenPath, Fx.tokenResponse(access: "at-2", refresh: nil, id: nil, scope: nil))
    let m = manager(store, fake)
    #expect(try await m.accessToken() == "at-2")
    let saved = try #require(store.stored?.tokens)
    #expect(saved.refreshToken == "rt-1" && saved.idToken == "id-old" && saved.scopes == SIWC.scopes && saved.earliestRefreshAt == nil)
}

@Test func saveFailureNeverHandsOutAnUnpersistedToken() async throws {
    let store = SpyStore(signedIn(expiresIn: 30))
    store.setFailSaves(true)
    let fake = FakeHTTPTransport()
    fake.enqueue(Fx.tokenPath, Fx.tokenResponse(access: "at-2", refresh: "rt-2", id: Fx.idToken()))
    let m = manager(store, fake)
    #expect(await llmError { try await m.accessToken() } == .temporarilyUnavailable(code: "credential_store"))
    // The rotated token is kept in memory and persisted on the next call, without another refresh.
    store.setFailSaves(false)
    #expect(try await m.accessToken() == "at-2")
    #expect(store.stored?.tokens?.refreshToken == "rt-2" && fake.requests.count == 1)
}

@Test func forceRefreshRefreshesEvenWhenNotDue() async throws {
    let fake = FakeHTTPTransport()
    fake.enqueue(Fx.tokenPath, Fx.tokenResponse(access: "at-2", id: Fx.idToken()))
    let m = manager(InMemoryCredentialStore(signedIn(expiresIn: 3000)), fake)
    #expect(try await m.accessToken(forceRefresh: true) == "at-2" && fake.requests.count == 1)
}

@Test func terminalRefreshErrorKeepsRegistration() async throws {
    let store = InMemoryCredentialStore(signedIn(expiresIn: 30))
    let fake = FakeHTTPTransport()
    fake.enqueue(Fx.tokenPath, .json(400, ["error": "refresh_token_reused"]))
    let m = manager(store, fake)
    #expect(await llmError { try await m.accessToken() } == .needsSignIn)
    let saved = try #require(try store.load())
    #expect(saved.tokens == nil && saved.registration.clientID == "oaiapp_1")
    #expect(saved.registration.hostID == "urn:uuid:00000000-0000-4000-8000-000000000001")
    #expect(saved.hint == SIWCHint(idToken: "id-old", email: "a@b.c"))
    #expect(await m.state() == .needsSignIn)
    #expect(await llmError { try await m.accessToken() } == .needsSignIn && fake.requests.count == 1)
}

@Test func changedSubjectOnRefreshNeedsSignIn() async throws {
    let store = InMemoryCredentialStore(signedIn(expiresIn: 30))
    let fake = FakeHTTPTransport()
    fake.enqueue(Fx.tokenPath, Fx.tokenResponse(access: "at-2", id: Fx.idToken(sub: "user-2")))
    let m = manager(store, fake)
    #expect(await llmError { try await m.accessToken() } == .needsSignIn)
    let saved = try #require(try store.load())
    #expect(saved.tokens == nil && saved.registration.clientID == "oaiapp_1" && saved.hint?.idToken == "id-old")
}

@Test func refreshIDTokenIsValidatedWithoutNonce() async throws {
    let fake = FakeHTTPTransport()
    // A refresh-time ID token carries no nonce (or a stale one): either is fine.
    fake.enqueue(Fx.tokenPath, Fx.tokenResponse(access: "at-2", id: Fx.idToken(nonce: "from-sign-in")))
    let m = manager(InMemoryCredentialStore(signedIn(expiresIn: 30)), fake)
    #expect(try await m.accessToken() == "at-2")
    // A badly signed / wrong-audience ID token is not accepted.
    fake.enqueue(Fx.tokenPath, Fx.tokenResponse(access: "at-3", id: Fx.idToken(aud: "oaiapp_other")))
    #expect(await llmError { try await m.accessToken(forceRefresh: true) } == .needsSignIn)
}

@Test func transientRefreshFailureUsesStillValidToken() async throws {
    let original = signedIn(expiresIn: 30)
    let store = SpyStore(original)
    let fake = FakeHTTPTransport()
    fake.enqueue(Fx.tokenPath, .json(503, ["error": "temporarily_unavailable"]))
    fake.enqueue(Fx.tokenPath, error: URLError(.notConnectedToInternet))
    let m = manager(store, fake)
    #expect(try await m.accessToken() == "at-1")
    #expect(try await m.accessToken() == "at-1")
    #expect(store.saves.isEmpty && store.stored == original && fake.requests.count == 2)
}

@Test func transientRefreshFailureWithExpiredTokenIsTemporarilyUnavailable() async throws {
    let original = signedIn(expiresIn: -10)
    let store = InMemoryCredentialStore(original)
    let fake = FakeHTTPTransport()
    fake.enqueue(Fx.tokenPath, FakeHTTPResponse(status: 502, body: Data("bad gateway".utf8)))
    let m = manager(store, fake)
    #expect(await llmError { try await m.accessToken() } == .temporarilyUnavailable(code: nil))
    #expect(try store.load() == original)
}

@Test func invalidClientOnRefreshForgetsTheClientAndNeedsSignIn() async throws {
    let store = InMemoryCredentialStore(signedIn(expiresIn: 30))
    let fake = FakeHTTPTransport()
    fake.enqueue(Fx.tokenPath, .json(401, ["error": "invalid_client"]))
    let m = manager(store, fake)
    #expect(await llmError { try await m.accessToken() } == .needsSignIn)
    let saved = try #require(try store.load())
    #expect(saved.tokens == nil && saved.registration.clientID == nil && saved.registration.hostID.hasPrefix("urn:uuid:"))
    #expect(await m.state() == .needsSignIn)
}

@Test func stateAndErrorsWithoutUsableTokens() async throws {
    let fake = FakeHTTPTransport()
    let none = manager(InMemoryCredentialStore(), fake)
    #expect(await none.state() == .signedOut)
    #expect(await llmError { try await none.accessToken() } == .notSignedIn)

    let registeredOnly = manager(InMemoryCredentialStore(Fx.account(tokens: nil)), fake)
    #expect(await registeredOnly.state() == .signedOut)
    #expect(await llmError { try await registeredOnly.accessToken() } == .notSignedIn)

    let expired = manager(InMemoryCredentialStore(Fx.account(tokens: nil, hint: SIWCHint(idToken: "x", email: nil))), fake)
    #expect(await expired.state() == .needsSignIn)
    #expect(await llmError { try await expired.accessToken() } == .needsSignIn)

    let noPlan = manager(InMemoryCredentialStore(signedIn(expiresIn: 30, scopes: ["openid"])), fake)
    #expect(await noPlan.state() == .signedIn(email: "a@b.c", planUsageEnabled: false))
    #expect(await llmError { try await noPlan.accessToken() } == .planUsageDisabled)
    #expect(fake.requests.isEmpty)
}

@Test func refreshIfDueRefreshesOnlyWhenDueAndSwallowsErrors() async throws {
    let fake = FakeHTTPTransport()
    let fresh = manager(InMemoryCredentialStore(signedIn(expiresIn: 3000)), fake)
    await fresh.refreshIfDue()
    #expect(fake.requests.isEmpty)

    let store = InMemoryCredentialStore(signedIn(expiresIn: 30))
    fake.enqueue(Fx.tokenPath, FakeHTTPResponse(status: 503))
    let due = manager(store, fake)
    await due.refreshIfDue()
    #expect(fake.requests.count == 1)
    #expect(try store.load()?.tokens?.accessToken == "at-1")
    fake.enqueue(Fx.tokenPath, Fx.tokenResponse(access: "at-2", id: Fx.idToken()))
    await due.refreshIfDue()
    #expect(try store.load()?.tokens?.accessToken == "at-2")
}

@Test func signOutKeepsRegistrationDropsHint() async throws {
    let store = InMemoryCredentialStore(Fx.account(tokens: Fx.tokens(expiresAt: Fx.t0.addingTimeInterval(3000)),
                                                   hint: SIWCHint(idToken: "old", email: "a@b.c")))
    let m = manager(store, FakeHTTPTransport())
    try await m.signOut()
    let saved = try #require(try store.load())
    #expect(saved.tokens == nil && saved.hint == nil && saved.registration.clientID == "oaiapp_1")
    #expect(await m.state() == .signedOut)
    #expect(await llmError { try await m.accessToken() } == .notSignedIn)
}

@Test func signOutDuringRefreshDiscardsTheResult() async throws {
    let store = InMemoryCredentialStore(signedIn(expiresIn: 30))
    let fake = FakeHTTPTransport()
    let gate = Mutex(false)
    fake.handle(Fx.tokenPath) { _ in
        while !gate.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
        return Fx.tokenResponse(access: "at-2", id: Fx.idToken())
    }
    let m = manager(store, fake)
    let pending = Task { try await m.accessToken() }
    while fake.requests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
    try await m.signOut()
    gate.withLock { $0 = true }
    #expect(await llmError { try await pending.value } == .notSignedIn)
    #expect(try store.load()?.tokens == nil)
    #expect(await m.state() == .signedOut)
}

@Test func didSignInReplacesTheSession() async throws {
    let fake = FakeHTTPTransport()
    #expect(await manager(InMemoryCredentialStore(), fake).state() == .signedOut)
    let store = SpyStore(nil)
    let m2 = manager(store, fake)
    try await m2.didSignIn(signedIn(expiresIn: 3000))
    #expect(store.stored == signedIn(expiresIn: 3000))  // didSignIn persists
    #expect(await m2.state() == .signedIn(email: "a@b.c", planUsageEnabled: true))
    #expect(try await m2.accessToken() == "at-1")
    // A failed save leaves the previous session in place.
    store.setFailSaves(true)
    await #expect(throws: SpyStore.SaveFailed.self) { try await m2.didSignIn(Fx.account(tokens: nil)) }
    #expect(try await m2.accessToken() == "at-1")
}

// MARK: - Refresh ID token: identity failures vs. unavailable verification

private let otherKey = FxKey(kid: "fx-k1")  // same kid as the JWKS key, different key

@Test func rotationIsSavedBeforeTheIDTokenIsValidated() async throws {
    let store = SpyStore(signedIn(expiresIn: 30))
    let seen = Mutex<String?>(nil)
    let jwks = FxJWKS { seen.withLock { $0 = store.stored?.tokens?.refreshToken } }
    let fake = FakeHTTPTransport()
    fake.enqueue(Fx.tokenPath, Fx.tokenResponse(access: "at-2", refresh: "rt-2", id: Fx.idToken()))
    #expect(try await manager(store, fake, jwks: jwks).accessToken() == "at-2")
    #expect(seen.withLock { $0 } == "rt-2")
}

@Test func unreachableJWKSKeepsTheRotationAndTheOldIDToken() async throws {
    let store = SpyStore(signedIn(expiresIn: 30))
    let jwks = FxJWKS { throw URLError(.notConnectedToInternet) }
    let fake = FakeHTTPTransport()
    fake.enqueue(Fx.tokenPath, Fx.tokenResponse(access: "at-2", refresh: "rt-2", id: Fx.idToken(email: "new@b.c")))
    let m = manager(store, fake, jwks: jwks)
    #expect(try await m.accessToken() == "at-2")
    let saved = try #require(store.stored?.tokens)
    #expect(saved.accessToken == "at-2" && saved.refreshToken == "rt-2")
    #expect(saved.idToken == "id-old" && saved.email == "a@b.c" && saved.subject == "user-1")
    #expect(await m.state() == .signedIn(email: "a@b.c", planUsageEnabled: true))
}

@Test(arguments: ["jwks", "kid"])
func jwksFailuresAreNotIdentityFailures(_ check: String) async throws {
    let store = InMemoryCredentialStore(signedIn(expiresIn: 30))
    let jwks = FxJWKS { throw AuthError.idToken(check) }
    let fake = FakeHTTPTransport()
    fake.enqueue(Fx.tokenPath, Fx.tokenResponse(access: "at-2", refresh: "rt-2", id: Fx.idToken()))
    #expect(try await manager(store, fake, jwks: jwks).accessToken() == "at-2")
    #expect(try store.load()?.tokens?.refreshToken == "rt-2")
}

@Test func clockSkewOnTheIDTokenKeepsTheRotation() async throws {
    let store = InMemoryCredentialStore(signedIn(expiresIn: 30))
    let fake = FakeHTTPTransport()
    // Issued "two hours in the future" by our clock: iat fails, the subject still matches.
    fake.enqueue(Fx.tokenPath, Fx.tokenResponse(access: "at-2", refresh: "rt-2", id: Fx.idToken(now: Fx.t0.addingTimeInterval(7200))))
    #expect(try await manager(store, fake).accessToken() == "at-2")
    #expect(try store.load()?.tokens?.idToken == "id-old")
}

@Test func unverifiedSubjectMismatchWithJWKSDownNeedsSignIn() async throws {
    let store = InMemoryCredentialStore(signedIn(expiresIn: 30))
    let jwks = FxJWKS { throw URLError(.timedOut) }
    let fake = FakeHTTPTransport()
    fake.enqueue(Fx.tokenPath, Fx.tokenResponse(access: "at-2", refresh: "rt-2", id: Fx.idToken(sub: "user-2")))
    let m = manager(store, fake, jwks: jwks)
    #expect(await llmError { try await m.accessToken() } == .needsSignIn)
    let saved = try #require(try store.load())
    #expect(saved.tokens == nil && saved.registration.clientID == "oaiapp_1" && saved.hint?.idToken == "id-old")
}

@Test func badSignatureAgainstAHeldKeyNeedsSignIn() async throws {
    let store = InMemoryCredentialStore(signedIn(expiresIn: 30))
    let fake = FakeHTTPTransport()
    fake.enqueue(Fx.tokenPath, Fx.tokenResponse(access: "at-2", refresh: "rt-2", id: Fx.idToken(signer: otherKey)))
    let m = manager(store, fake)
    #expect(await llmError { try await m.accessToken() } == .needsSignIn)
    #expect(try store.load()?.tokens == nil)
    #expect(await m.state() == .needsSignIn)
}

// MARK: - 401 handling and store availability

@Test func forceRefreshSkipsWhenTheRejectedTokenIsStale() async throws {
    let fake = FakeHTTPTransport()
    fake.enqueue(Fx.tokenPath, Fx.tokenResponse(access: "at-2", refresh: "rt-2", id: Fx.idToken()))
    let m = manager(InMemoryCredentialStore(signedIn(expiresIn: 3000)), fake)
    // A token another caller already replaced: hand out the current one, no refresh.
    #expect(try await m.forceRefresh(rejected: "at-0") == "at-1" && fake.requests.isEmpty)
    // The current token was rejected: refresh.
    #expect(try await m.forceRefresh(rejected: "at-1") == "at-2" && fake.requests.count == 1)
    #expect(try await m.forceRefresh(rejected: "at-1") == "at-2" && fake.requests.count == 1)
}

private final class FailingLoadStore: CredentialStore {
    struct Locked: Error {}
    func load() throws -> SIWCAccount? { throw Locked() }
    func save(_ a: SIWCAccount) throws { throw Locked() }
    func delete() throws {}
}

@Test func unreadableStoreIsUnavailableNotSignedOut() async {
    let m = manager(FailingLoadStore(), FakeHTTPTransport())
    #expect(await m.state() == .unavailable)
    #expect(await llmError { try await m.accessToken() } == .temporarilyUnavailable(code: "credential_store"))
}

@Test func forgetRegistrationDeletesEverythingSoNextSignInReRegisters() async throws {
    let store = InMemoryCredentialStore(signedIn(expiresIn: 3000))
    let m = manager(store, FakeHTTPTransport())
    try await m.forgetRegistration()
    #expect(try store.load() == nil)
    #expect(await m.state() == .signedOut)
    #expect(await llmError { try await m.accessToken() } == .notSignedIn)
}
