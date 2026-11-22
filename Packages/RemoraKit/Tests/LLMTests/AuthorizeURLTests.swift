import Foundation
import Testing
@testable import LLM

private func queryDict(_ url: URL) -> [String: String] {
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
}

@Test func firstRegistrationURL() {
    let a = AuthorizeURL.make(port: 1455, account: .init(registration: .init(hostID: "urn:uuid:x", clientID: nil), tokens: nil, hint: nil), state: "S", nonce: "N", pkce: .init(verifier: "v", challenge: "c"))
    let q = queryDict(a.url)
    #expect(a.url.absoluteString.hasPrefix("https://auth.openai.com/api/accounts/authorize?"))
    #expect(q["client_id"] == "dynamic_agent_client" && q["agent_name_hint"] == "Remora" && q["redirect_uri"] == "http://127.0.0.1:1455/auth/callback")
    #expect(q["scope"] == "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct" && q["resource"] == "https://api.openai.com/v1")
    #expect(q["code_challenge_method"] == "S256" && q["ext_agent_host_id"] == "urn:uuid:x" && q["id_token_hint"] == nil)
    #expect(q["response_type"] == "code" && q["state"] == "S" && q["nonce"] == "N" && q["code_challenge"] == "c")
    #expect(q["login_hint"] == nil)
    #expect(a.state == "S" && a.nonce == "N" && a.pkce.verifier == "v")
    #expect(a.clientID == "dynamic_agent_client" && a.redirectURI == "http://127.0.0.1:1455/auth/callback")
}

@Test func firstRegistrationIgnoresHint() {
    let account = SIWCAccount(registration: .init(hostID: "urn:uuid:x", clientID: nil), tokens: nil, hint: .init(idToken: "t", email: "a@b.c"))
    let q = queryDict(AuthorizeURL.make(port: 1456, account: account, state: "S", nonce: "N", pkce: .init(verifier: "v", challenge: "c")).url)
    #expect(q["id_token_hint"] == nil && q["login_hint"] == nil && q["agent_name_hint"] == "Remora")
    #expect(q["redirect_uri"] == "http://127.0.0.1:1456/auth/callback")
}

@Test func reloginUsesIssuedIDAndHints() {
    let account = SIWCAccount(registration: .init(hostID: "urn:uuid:x", clientID: "oaiapp_1"), tokens: nil, hint: .init(idToken: "t", email: "a@b.c"))
    let a = AuthorizeURL.make(port: 1455, account: account, state: "S", nonce: "N", pkce: .init(verifier: "v", challenge: "c"))
    let q = queryDict(a.url)
    #expect(q["client_id"] == "oaiapp_1" && a.clientID == "oaiapp_1")
    #expect(q["id_token_hint"] == "t" && q["login_hint"] == "a@b.c")
    #expect(q["agent_name_hint"] == nil)
    #expect(q["ext_agent_host_id"] == "urn:uuid:x")
}

@Test func reloginWithoutEmailOmitsLoginHint() {
    let account = SIWCAccount(registration: .init(hostID: "urn:uuid:x", clientID: "oaiapp_1"), tokens: nil, hint: .init(idToken: "t", email: nil))
    let q = queryDict(AuthorizeURL.make(port: 1455, account: account, state: "S", nonce: "N", pkce: .init(verifier: "v", challenge: "c")).url)
    #expect(q["id_token_hint"] == "t" && q["login_hint"] == nil)
}

@Test func afterSignOutNoHints() {
    let account = SIWCAccount(registration: .init(hostID: "urn:uuid:x", clientID: "oaiapp_1"), tokens: nil, hint: nil)
    let q = queryDict(AuthorizeURL.make(port: 1455, account: account, state: "S", nonce: "N", pkce: .init(verifier: "v", challenge: "c")).url)
    #expect(q["client_id"] == "oaiapp_1")
    #expect(q["id_token_hint"] == nil && q["login_hint"] == nil && q["agent_name_hint"] == nil)
}

@Test func reservedCharactersArePercentEncoded() {
    let account = SIWCAccount(registration: .init(hostID: "urn:uuid:x", clientID: "oaiapp_1"), tokens: nil, hint: .init(idToken: "t", email: "a+b@c.d"))
    let a = AuthorizeURL.make(port: 1455, account: account, state: "S", nonce: "N", pkce: .init(verifier: "v", challenge: "c"))
    #expect(a.url.absoluteString.contains("login_hint=a%2Bb%40c.d"))
    #expect(queryDict(a.url)["login_hint"] == "a+b@c.d")
}
