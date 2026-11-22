import Foundation
import Security
import Testing
@testable import LLM

@Test func keychainQueryShape() {
    let q = KeychainCredentialStore.baseQuery(service: "s", account: "a")
    #expect(q[kSecClass as String] as! CFString == kSecClassGenericPassword && q[kSecAttrSynchronizable as String] as? Bool == false)
    #expect(q[kSecAttrService as String] as? String == "s" && q[kSecAttrAccount as String] as? String == "a")
    #expect(q[kSecUseDataProtectionKeychain as String] == nil)
}

@Test func keychainWriteAttributes() {
    let attrs = KeychainCredentialStore.writeAttributes(data: Data("x".utf8))
    #expect(attrs[kSecValueData as String] as? Data == Data("x".utf8))
    #expect(attrs[kSecAttrAccessible as String] as! CFString == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    #expect(attrs[kSecAttrLabel as String] as? String == "Remora: ChatGPT sign-in")
}

@Test func keychainDefaults() {
    let s = KeychainCredentialStore()
    #expect(s.service == "dev.remora.Remora.siwc" && s.account == "chatgpt")
}

private func sampleAccount(scopes: [String]) -> SIWCAccount {
    SIWCAccount(
        registration: .init(hostID: "urn:uuid:x", clientID: "oaiapp_1"),
        tokens: .init(idToken: "i", accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSince1970: 1_700_003_600.5),
                      earliestRefreshAt: Date(timeIntervalSince1970: 1_700_003_240), scopes: scopes, subject: "user-1", email: "a@b.c"),
        hint: .init(idToken: "old", email: "a@b.c"))
}

@Test func accountJSONRoundTripAndPlanUsageFlag() throws {
    let without = sampleAccount(scopes: ["openid", "profile", "email", "offline_access", "resource.invoke"])
    #expect(!without.planUsageEnabled)
    let data = try KeychainCredentialStore.encode(without)
    #expect(try KeychainCredentialStore.decode(data) == without)
    #expect(try JSONDecoder().decode(SIWCAccount.self, from: JSONEncoder().encode(without)) == without)

    let with = sampleAccount(scopes: SIWC.scopes)
    #expect(with.planUsageEnabled)
    #expect(!SIWCAccount(registration: .init(hostID: "h", clientID: nil), tokens: nil, hint: nil).planUsageEnabled)
}

@Test func freshAccountHasLowercasedURNUUIDHostID() {
    let a = SIWCAccount.fresh()
    #expect(a.registration.hostID.hasPrefix("urn:uuid:"))
    let uuid = String(a.registration.hostID.dropFirst("urn:uuid:".count))
    #expect(UUID(uuidString: uuid) != nil && uuid == uuid.lowercased())
    #expect(a.registration.clientID == nil && a.tokens == nil && a.hint == nil)
    #expect(SIWCAccount.fresh().registration.hostID != a.registration.hostID)
}

@Test func inMemoryStoreRoundTrip() throws {
    let store = InMemoryCredentialStore()
    #expect(try store.load() == nil)
    let a = sampleAccount(scopes: SIWC.scopes)
    try store.save(a)
    #expect(try store.load() == a)
    try store.delete()
    #expect(try store.load() == nil)
    #expect(try InMemoryCredentialStore(a).load() == a)
}

@Test func constants() {
    #expect(SIWC.authorizeURL.absoluteString == "https://auth.openai.com/api/accounts/authorize")
    #expect(SIWC.tokenURL.absoluteString == "https://auth.openai.com/api/accounts/oauth/token")
    #expect(SIWC.issuer == "https://auth.openai.com")
    #expect(SIWC.jwksURL.absoluteString == "https://auth.openai.com/.well-known/jwks.json")
    #expect(SIWC.apiBase == "https://api.openai.com/v1")
    #expect(SIWC.dynamicClientID == "dynamic_agent_client" && SIWC.agentName == "Remora")
    #expect(SIWC.requiredScope == "chatgpt.tokens.use.direct" && SIWC.scopes.contains(SIWC.requiredScope))
    #expect(SIWC.callbackPath == "/auth/callback" && SIWC.ports == [1455, 1456, 1457, 1458, 1459])
    #expect(SIWC.callbackTimeout == .seconds(600))
    #expect(SIWC.usageSettingsURL.absoluteString == "https://chatgpt.com/settings/usage")
}

@Test func secretBearingTypesRedactDescriptions() {
    let tokens = SIWCTokens(idToken: "SECRET_ID", accessToken: "SECRET_ACCESS", refreshToken: "SECRET_REFRESH",
                            expiresAt: Date(timeIntervalSince1970: 1_700_000_000), earliestRefreshAt: nil,
                            scopes: SIWC.scopes, subject: "SECRET_SUB", email: "secret@example.com")
    let hint = SIWCHint(idToken: "SECRET_HINT", email: "secret@example.com")
    let account = SIWCAccount(registration: .init(hostID: "urn:uuid:x", clientID: "oaiapp_1"), tokens: tokens, hint: hint)
    let pkce = PKCE(verifier: "SECRET_VERIFIER", challenge: "SECRET_CHALLENGE")
    let attempt = AuthorizeURL.make(port: 1455, account: account, state: "SECRET_STATE", nonce: "SECRET_NONCE", pkce: pkce)
    let claims = IDTokenClaims(subject: "SECRET_SUB", email: "secret@example.com", expiresAt: Date())
    let values: [Any] = [tokens, hint, account, pkce, attempt, claims]
    for v in values {
        for s in [String(describing: v), String(reflecting: v), dumped(v)] {
            #expect(!s.contains("SECRET") && !s.contains("secret@"), "\(type(of: v)) leaked")
        }
    }
    #expect(String(describing: account).contains("oaiapp_1"))
    #expect(String(describing: tokens).contains("earliestRefreshAt: nil, "))
    #expect(String(describing: SIWCTokens(idToken: "i", accessToken: "a", refreshToken: nil, expiresAt: Date(), earliestRefreshAt: nil,
                                          scopes: [], subject: "s", email: nil)).contains("refreshToken: nil"))
    #expect(String(describing: attempt).contains("oaiapp_1"))
}
