import Foundation
import LLMTestSupport
import Synchronization
import Testing
@testable import LLM

// The browser is fake, the token endpoint is a FakeHTTPTransport, the listener is a real loopback
// listener on an ephemeral 127.0.0.1 port (never 1455–1459).

private func makeFlow(store: any CredentialStore, fake: FakeHTTPTransport, browser: FakeBrowser,
                      tokens: TokenManager? = nil) -> SignInFlow {
    let manager = tokens ?? TokenManager(store: store, http: fake, validator: Fx.validator(), now: { Fx.t0 })
    return SignInFlow(tokens: manager, http: fake, validator: Fx.validator(), browser: browser,
                      server: { LoopbackServer(ports: []) }, callbackTimeout: .seconds(5), now: { Fx.t0 })
}

/// Token endpoint answering with an ID token for `aud`, carrying the nonce the browser saw.
private func answerTokens(_ fake: FakeHTTPTransport, _ browser: FakeBrowser, aud: String = "oaiapp_1", sub: String = "user-1",
                          scope: String? = SIWC.scopes.joined(separator: " ")) {
    fake.handle(Fx.tokenPath) { _ in
        Fx.tokenResponse(access: "at-1", refresh: "rt-1", id: Fx.idToken(sub: sub, aud: aud, nonce: browser.authorizeQuery["nonce"]),
                         scope: scope, earliest: Fx.t0.timeIntervalSince1970 + 3240)
    }
}

private func failure(_ body: () async throws -> SIWCAccount) async -> AuthError? {
    do { _ = try await body(); return nil } catch let e as AuthError { return e } catch { return .idToken("unexpected \(type(of: error))") }
}

@Test func signInFirstRegistrationSavesIssuedClient() async throws {
    let store = InMemoryCredentialStore()
    let fake = FakeHTTPTransport()
    let browser = FakeBrowser.approving(clientID: "oaiapp_1", strays: ["/favicon.ico", "/other?state=x"])
    answerTokens(fake, browser)
    let a = try await makeFlow(store: store, fake: fake, browser: browser).signIn()

    #expect(a.registration.clientID == "oaiapp_1" && a.tokens?.subject == "user-1" && a.planUsageEnabled)
    #expect(a.tokens?.accessToken == "at-1" && a.tokens?.refreshToken == "rt-1" && a.tokens?.email == "a@b.c")
    #expect(a.tokens?.expiresAt == Fx.t0.addingTimeInterval(3600) && a.tokens?.earliestRefreshAt == Fx.t0.addingTimeInterval(3240))
    #expect(a.hint == nil && a.registration.hostID.hasPrefix("urn:uuid:"))
    #expect(try store.load() == a)

    let q = browser.authorizeQuery
    #expect(q["client_id"] == SIWC.dynamicClientID && q["agent_name_hint"] == "Remora")
    #expect(fake.requests.count == 1)
    let form = fake.requests[0].formBody
    #expect(fake.requests[0].url == SIWC.tokenURL && fake.requests[0].httpMethod == "POST")
    #expect(form["resource"] == "https://api.openai.com/v1" && form["redirect_uri"]!.hasPrefix("http://127.0.0.1:"))
    #expect(form["redirect_uri"] == q["redirect_uri"] && form["grant_type"] == "authorization_code")
    #expect(form["client_id"] == "oaiapp_1" && form["code"] == "c")
    #expect(PKCE.challenge(for: form["code_verifier"]!) == q["code_challenge"])
    #expect(Set(form.keys) == ["grant_type", "client_id", "code", "code_verifier", "redirect_uri", "resource"])
    #expect(await browser.callbackPage()?.contains("Signed in to Remora. You can close this tab.") == true)
}

@Test func freshHostIDIsPersistedBeforeTheBrowserOpens() async {
    let store = InMemoryCredentialStore()
    let browser = FakeBrowser(opens: false) { _ in nil }
    let e = await failure { try await makeFlow(store: store, fake: FakeHTTPTransport(), browser: browser).signIn() }
    #expect(e == .browserUnavailable)
    let saved = try? store.load()
    #expect(saved?.registration.clientID == nil && saved?.registration.hostID == Fx.query(browser.urls[0])["ext_agent_host_id"])
}

@Test func stateMismatchNeverExchanges() async {
    let fake = FakeHTTPTransport()
    let browser = FakeBrowser.approving(extra: ["state": "evil"])
    answerTokens(fake, browser)
    let e = await failure { try await makeFlow(store: InMemoryCredentialStore(), fake: fake, browser: browser).signIn() }
    #expect(e == .stateMismatch && fake.requests.isEmpty)
    #expect(await browser.callbackPage()?.contains("Sign-in failed. Return to Remora.") == true)
}

@Test func missingStateNeverExchanges() async {
    let fake = FakeHTTPTransport()
    let browser = FakeBrowser.approving(removing: ["state"])
    answerTokens(fake, browser)
    let e = await failure { try await makeFlow(store: InMemoryCredentialStore(), fake: fake, browser: browser).signIn() }
    #expect(e == .stateMismatch && fake.requests.isEmpty)
}

@Test func accessDeniedNeverExchanges() async {
    let fake = FakeHTTPTransport()
    let browser = FakeBrowser.approving(extra: ["error": "access_denied"], removing: ["code"])
    let e = await failure { try await makeFlow(store: InMemoryCredentialStore(), fake: fake, browser: browser).signIn() }
    #expect(e == .accessDenied && fake.requests.isEmpty)
}

@Test func errorWithWrongStateIsAStateMismatch() async {
    let fake = FakeHTTPTransport()
    let browser = FakeBrowser.approving(extra: ["error": "access_denied", "state": "evil"], removing: ["code"])
    let e = await failure { try await makeFlow(store: InMemoryCredentialStore(), fake: fake, browser: browser).signIn() }
    #expect(e == .stateMismatch && fake.requests.isEmpty)
}

@Test func otherAuthorizationErrorNeverExchanges() async {
    let fake = FakeHTTPTransport()
    let browser = FakeBrowser.approving(extra: ["error": "server_error"], removing: ["code"])
    let e = await failure { try await makeFlow(store: InMemoryCredentialStore(), fake: fake, browser: browser).signIn() }
    #expect(e == .authorizationFailed("server_error") && fake.requests.isEmpty)
}

@Test func issuerMismatchNeverExchanges() async {
    let fake = FakeHTTPTransport()
    let browser = FakeBrowser.approving(extra: ["iss": "https://evil.example"])
    answerTokens(fake, browser)
    let e = await failure { try await makeFlow(store: InMemoryCredentialStore(), fake: fake, browser: browser).signIn() }
    #expect(e == .issuerMismatch && fake.requests.isEmpty)
}

@Test func firstRegistrationWithoutClientIDIsIncomplete() async {
    let fake = FakeHTTPTransport()
    let browser = FakeBrowser.approving(clientID: nil)
    answerTokens(fake, browser)
    let e = await failure { try await makeFlow(store: InMemoryCredentialStore(), fake: fake, browser: browser).signIn() }
    #expect(e == .registrationIncomplete && fake.requests.isEmpty)
    let dynamic = FakeBrowser.approving(clientID: SIWC.dynamicClientID)
    let e2 = await failure { try await makeFlow(store: InMemoryCredentialStore(), fake: fake, browser: dynamic).signIn() }
    #expect(e2 == .registrationIncomplete && fake.requests.isEmpty)
}

@Test func audienceIsCheckedAgainstTheCallbackClientID() async {
    let store = InMemoryCredentialStore()
    let fake = FakeHTTPTransport()
    let browser = FakeBrowser.approving(clientID: "oaiapp_1")
    answerTokens(fake, browser, aud: "oaiapp_other")
    let e = await failure { try await makeFlow(store: store, fake: fake, browser: browser).signIn() }
    #expect(e == .idToken("aud"))
    #expect((try? store.load())?.tokens == nil && (try? store.load())?.registration.clientID == nil)
}

@Test func nonceMismatchSavesNothing() async {
    let store = InMemoryCredentialStore()
    let fake = FakeHTTPTransport()
    let browser = FakeBrowser.approving()
    fake.handle(Fx.tokenPath) { _ in Fx.tokenResponse(id: Fx.idToken(nonce: "other")) }
    let e = await failure { try await makeFlow(store: store, fake: fake, browser: browser).signIn() }
    #expect(e == .idToken("nonce") && (try? store.load())?.tokens == nil)
    #expect(await browser.callbackPage()?.contains("Sign-in failed") == true)
}

@Test func missingIDTokenFails() async {
    let fake = FakeHTTPTransport()
    let browser = FakeBrowser.approving()
    fake.handle(Fx.tokenPath) { _ in Fx.tokenResponse(id: nil) }
    let e = await failure { try await makeFlow(store: InMemoryCredentialStore(), fake: fake, browser: browser).signIn() }
    #expect(e == .missingIDToken)
}

@Test func missingRequiredScopeSavesButPlanUsageDisabled() async throws {
    let store = InMemoryCredentialStore()
    let fake = FakeHTTPTransport()
    let browser = FakeBrowser.approving()
    answerTokens(fake, browser, scope: "openid profile email offline_access resource.invoke")
    let a = try await makeFlow(store: store, fake: fake, browser: browser).signIn()
    #expect(!a.planUsageEnabled && a.tokens?.accessToken == "at-1" && a.registration.clientID == "oaiapp_1")
    #expect(try store.load() == a)
}

@Test func scopesFallBackToTheCallback() async throws {
    let fake = FakeHTTPTransport()
    let browser = FakeBrowser.approving(extra: ["scope": "openid email"])
    answerTokens(fake, browser, scope: nil)
    let a = try await makeFlow(store: InMemoryCredentialStore(), fake: fake, browser: browser).signIn()
    #expect(a.tokens?.scopes == ["openid", "email"] && !a.planUsageEnabled)
}

@Test func reSignInUsesRetainedClientWithHints() async throws {
    let old = Fx.account(clientID: "oaiapp_1", tokens: nil, hint: SIWCHint(idToken: "old-id", email: "a@b.c"))
    let store = InMemoryCredentialStore(old)
    let fake = FakeHTTPTransport()
    let browser = FakeBrowser.approving(clientID: nil)  // the re-login callback carries no client_id
    answerTokens(fake, browser)
    let a = try await makeFlow(store: store, fake: fake, browser: browser).signIn()
    let q = browser.authorizeQuery
    #expect(q["client_id"] == "oaiapp_1" && q["id_token_hint"] == "old-id" && q["login_hint"] == "a@b.c" && q["agent_name_hint"] == nil)
    #expect(a.registration == old.registration && a.hint == nil && a.tokens?.accessToken == "at-1")
    #expect(fake.requests[0].formBody["client_id"] == "oaiapp_1")
}

@Test func reSignInRejectsADifferentCallbackClientID() async {
    let old = Fx.account(clientID: "oaiapp_1", tokens: nil, hint: SIWCHint(idToken: "old-id", email: nil))
    let store = InMemoryCredentialStore(old)
    let fake = FakeHTTPTransport()
    let browser = FakeBrowser.approving(clientID: "oaiapp_2")
    answerTokens(fake, browser, aud: "oaiapp_2")
    let e = await failure { try await makeFlow(store: store, fake: fake, browser: browser).signIn() }
    #expect(e == .clientIDMismatch && fake.requests.isEmpty && (try? store.load()) == old)
}

@Test func reSignInAsAnotherAccountWhileSignedInIsRejected() async {
    let old = Fx.account(tokens: Fx.tokens(expiresAt: Fx.t0.addingTimeInterval(3600), sub: "user-1"))
    let store = InMemoryCredentialStore(old)
    let fake = FakeHTTPTransport()
    let browser = FakeBrowser.approving(clientID: nil)
    answerTokens(fake, browser, sub: "user-2")
    let e = await failure { try await makeFlow(store: store, fake: fake, browser: browser).signIn() }
    #expect(e == .identityMismatch && (try? store.load()) == old)
}

@Test func invalidGrantOnExchangeIsASignInFailureNotExpiry() async {
    let old = Fx.account(clientID: "oaiapp_1", tokens: nil, hint: SIWCHint(idToken: "old-id", email: nil))
    let store = InMemoryCredentialStore(old)
    let fake = FakeHTTPTransport()
    let browser = FakeBrowser.approving(clientID: nil)
    fake.enqueue(Fx.tokenPath, .json(400, ["error": "invalid_grant"]))
    let e = await failure { try await makeFlow(store: store, fake: fake, browser: browser).signIn() }
    #expect(e == .tokenEndpoint(status: 400, code: "invalid_grant") && (try? store.load()) == old)
}

@Test func invalidClientWithRetainedClientResetsRegistration() async {
    let old = Fx.account(clientID: "oaiapp_1", tokens: nil, hint: SIWCHint(idToken: "old-id", email: nil))
    let store = InMemoryCredentialStore(old)
    let fake = FakeHTTPTransport()
    let browser = FakeBrowser.approving(clientID: nil)
    fake.enqueue(Fx.tokenPath, .json(401, ["error": "invalid_client"]))
    let e = await failure { try await makeFlow(store: store, fake: fake, browser: browser).signIn() }
    #expect(e == .invalidClient)
    let saved = try? store.load()
    #expect(saved?.registration.clientID == nil && saved?.registration.hostID == old.registration.hostID)
}

@Test func invalidClientOnFirstRegistrationKeepsNothing() async {
    let store = InMemoryCredentialStore()
    let fake = FakeHTTPTransport()
    let browser = FakeBrowser.approving(clientID: "oaiapp_1")
    fake.enqueue(Fx.tokenPath, .json(401, ["error": "invalid_client"]))
    let e = await failure { try await makeFlow(store: store, fake: fake, browser: browser).signIn() }
    #expect(e == .invalidClient && (try? store.load())?.registration.clientID == nil)
}

@Test func callbackTimeoutFails() async {
    let browser = FakeBrowser { _ in nil }  // opens, never calls back
    let tokens = TokenManager(store: InMemoryCredentialStore(), http: FakeHTTPTransport(), validator: Fx.validator())
    let flow = SignInFlow(tokens: tokens, http: FakeHTTPTransport(), validator: Fx.validator(), browser: browser,
                          server: { LoopbackServer(ports: []) }, callbackTimeout: .milliseconds(100), now: { Fx.t0 })
    let e = await failure { try await flow.signIn() }
    #expect(e == .timedOut)
}

@Test func missingIssuerNeverExchanges() async {
    let fake = FakeHTTPTransport()
    let browser = FakeBrowser.approving(removing: ["iss"])
    answerTokens(fake, browser)
    let e = await failure { try await makeFlow(store: InMemoryCredentialStore(), fake: fake, browser: browser).signIn() }
    #expect(e == .issuerMismatch && fake.requests.isEmpty)
}

@Test func noScopeAnywhereMeansTheRequestedScopes() async throws {
    let fake = FakeHTTPTransport()
    let browser = FakeBrowser.approving(removing: ["scope"])
    answerTokens(fake, browser, scope: nil)
    let a = try await makeFlow(store: InMemoryCredentialStore(), fake: fake, browser: browser).signIn()
    #expect(a.tokens?.scopes == SIWC.scopes && a.planUsageEnabled)
}

@Test func signInSavesThroughTheTokenManager() async throws {
    let store = SpyStore(nil)
    let fake = FakeHTTPTransport()
    let browser = FakeBrowser.approving()
    answerTokens(fake, browser)
    let tokens = TokenManager(store: store, http: fake, validator: Fx.validator(), now: { Fx.t0 })
    let a = try await makeFlow(store: store, fake: fake, browser: browser, tokens: tokens).signIn()
    #expect(await tokens.state() == .signedIn(email: "a@b.c", planUsageEnabled: true))
    #expect(try await tokens.accessToken() == "at-1" && store.stored == a)
}

@Test func aRacingRefreshCannotOverwriteAFreshSignIn() async throws {
    // Signed in, token due: a refresh is in flight (held) when a new sign-in completes.
    let store = InMemoryCredentialStore(Fx.account(tokens: Fx.tokens(access: "at-old", refresh: "rt-old",
                                                                     expiresAt: Fx.t0.addingTimeInterval(30))))
    let refreshHTTP = FakeHTTPTransport()
    let gate = Mutex(false)
    refreshHTTP.handle(Fx.tokenPath) { _ in
        while !gate.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
        return Fx.tokenResponse(access: "at-refreshed", refresh: "rt-refreshed", id: Fx.idToken())
    }
    let tokens = TokenManager(store: store, http: refreshHTTP, validator: Fx.validator(), now: { Fx.t0 })
    let pending = Task { try await tokens.accessToken() }
    while refreshHTTP.requests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }

    let signInHTTP = FakeHTTPTransport()
    let browser = FakeBrowser.approving(clientID: nil)
    answerTokens(signInHTTP, browser)  // access "at-1", refresh "rt-1"
    _ = try await makeFlow(store: store, fake: signInHTTP, browser: browser, tokens: tokens).signIn()
    gate.withLock { $0 = true }

    #expect(try await pending.value == "at-1")  // the refresh result is discarded
    let saved = try #require(try store.load()?.tokens)
    #expect(saved.accessToken == "at-1" && saved.refreshToken == "rt-1")
    #expect(try await tokens.accessToken() == "at-1")
}
