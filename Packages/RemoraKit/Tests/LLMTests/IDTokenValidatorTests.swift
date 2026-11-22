import Foundation
import Security
import Synchronization
import Testing
@testable import LLM

// MARK: - Test fixtures (in-memory RSA keys; nothing touches the Keychain)

private struct TestKey: @unchecked Sendable {
    let privateKey: SecKey
    let publicDER: Data
    let jwk: JWK

    init(kid: String, bits: Int = 2048) {
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: bits,
            kSecAttrIsPermanent as String: false,
            kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: false],
        ]
        var error: Unmanaged<CFError>?
        privateKey = SecKeyCreateRandomKey(attrs as CFDictionary, &error)!
        let pub = SecKeyCopyPublicKey(privateKey)!
        publicDER = SecKeyCopyExternalRepresentation(pub, &error)! as Data
        let parts = RSAPublicKeyDER.decode(publicDER)!
        jwk = JWK(kid: kid, kty: "RSA", alg: "RS256", n: Base64URL.encode(parts.modulus), e: Base64URL.encode(parts.exponent))
    }

    func sign(_ input: Data) -> Data {
        var error: Unmanaged<CFError>?
        return SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, input as CFData, &error)! as Data
    }
}

private let keyA = TestKey(kid: "k1")
private let keyB = TestKey(kid: "k2")
private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func json(_ o: [String: Any]) -> String {
    Base64URL.encode(try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]))
}

private func makeJWT(header: [String: Any] = ["alg": "RS256", "kid": "k1", "typ": "JWT"],
                     claims: [String: Any] = [:], signer: TestKey? = keyA, signature: String? = nil) -> String {
    var c: [String: Any] = [
        "iss": "https://auth.openai.com", "aud": ["oaiapp_1"], "sub": "user-1", "email": "a@b.c",
        "nonce": "N", "exp": now.timeIntervalSince1970 + 3600, "iat": now.timeIntervalSince1970 - 10,
    ]
    for (k, v) in claims { if v is NSNull { c.removeValue(forKey: k) } else { c[k] = v } }
    let input = "\(json(header)).\(json(c))"
    let sig = signature ?? signer.map { Base64URL.encode($0.sign(Data(input.utf8))) } ?? ""
    return "\(input).\(sig)"
}

private final class FakeJWKS: JWKSProviding {
    private let state: Mutex<(calls: Int, forced: Int)> = Mutex((0, 0))
    let initial: [JWK]
    let refreshed: [JWK]
    init(_ initial: [JWK], refreshed: [JWK]? = nil) { self.initial = initial; self.refreshed = refreshed ?? initial }
    var calls: Int { state.withLock { $0.calls } }
    var forced: Int { state.withLock { $0.forced } }
    func keys(forceRefresh: Bool) async throws -> [JWK] {
        state.withLock { $0.calls += 1; if forceRefresh { $0.forced += 1 } }
        return forceRefresh ? refreshed : initial
    }
}

private func validator(_ jwks: FakeJWKS = FakeJWKS([keyA.jwk])) -> IDTokenValidator {
    IDTokenValidator(jwks: jwks, now: { now })
}

private func check(_ jwt: String, clientID: String = "oaiapp_1", nonce: String? = "N", jwks: FakeJWKS = FakeJWKS([keyA.jwk])) async -> AuthError? {
    do { _ = try await validator(jwks).validate(jwt, clientID: clientID, nonce: nonce); return nil }
    catch let e as AuthError { return e }
    catch { return .idToken("unexpected \(type(of: error))") }
}

// MARK: - Validation

@Test func acceptsValidToken() async throws {
    let claims = try await validator().validate(makeJWT(), clientID: "oaiapp_1", nonce: "N")
    #expect(claims == IDTokenClaims(subject: "user-1", email: "a@b.c", expiresAt: now.addingTimeInterval(3600)))
}

@Test func acceptsStringAudienceAndNilNonceAndNoEmail() async throws {
    let jwt = makeJWT(claims: ["aud": "oaiapp_1", "nonce": NSNull(), "email": NSNull()])
    let claims = try await validator().validate(jwt, clientID: "oaiapp_1", nonce: nil)
    #expect(claims.subject == "user-1" && claims.email == nil)
}

@Test func expiryWithinLeewayIsAccepted() async {
    #expect(await check(makeJWT(claims: ["exp": now.timeIntervalSince1970 - 30])) == nil)
    #expect(await check(makeJWT(claims: ["exp": now.timeIntervalSince1970 - 61])) == .idToken("exp"))
}

@Test(arguments: ["badSignature", "alg:none", "alg:HS256", "wrongIssuer", "wrongAudience", "expired", "wrongNonce", "unknownKid"])
func rejectsInvalid(_ c: String) async {
    let jwt: String
    let expected: String
    switch c {
    case "badSignature": jwt = makeJWT(signer: keyB); expected = "signature"
    case "alg:none": jwt = makeJWT(header: ["alg": "none", "kid": "k1"], signer: nil); expected = "alg"
    case "alg:HS256": jwt = makeJWT(header: ["alg": "HS256", "kid": "k1"], signature: Base64URL.encode(Data(repeating: 7, count: 32))); expected = "alg"
    case "wrongIssuer": jwt = makeJWT(claims: ["iss": "https://evil.example"]); expected = "iss"
    case "wrongAudience": jwt = makeJWT(claims: ["aud": ["someone_else"]]); expected = "aud"
    case "expired": jwt = makeJWT(claims: ["exp": now.timeIntervalSince1970 - 3600, "iat": now.timeIntervalSince1970 - 7200]); expected = "exp"
    case "wrongNonce": jwt = makeJWT(claims: ["nonce": "other"]); expected = "nonce"
    case "unknownKid": jwt = makeJWT(header: ["alg": "RS256", "kid": "nope"]); expected = "kid"
    default: Issue.record("unknown case"); return
    }
    #expect(await check(jwt) == .idToken(expected))
}

@Test func rejectsOtherClaimProblems() async {
    #expect(await check(makeJWT(claims: ["iat": now.timeIntervalSince1970 + 3600])) == .idToken("iat"))
    #expect(await check(makeJWT(claims: ["iat": NSNull()])) == .idToken("iat"))
    #expect(await check(makeJWT(claims: ["sub": NSNull()])) == .idToken("sub"))
    #expect(await check(makeJWT(claims: ["sub": ""])) == .idToken("sub"))
    #expect(await check(makeJWT(claims: ["exp": NSNull()])) == .idToken("exp"))
    #expect(await check(makeJWT(claims: ["nonce": NSNull()])) == .idToken("nonce"))
    #expect(await check(makeJWT(claims: ["iss": NSNull()])) == .idToken("iss"))
    #expect(await check(makeJWT(), clientID: "oaiapp_2") == .idToken("aud"))
    #expect(await check(makeJWT(header: ["alg": "RS256"])) == .idToken("kid"))
}

@Test func rejectsMalformedTokens() async {
    #expect(await check("abc") == .idToken("format"))
    #expect(await check("a.b.c.d") == .idToken("format"))
    #expect(await check("!!.??.**") == .idToken("header"))
    let valid = makeJWT()
    let parts = valid.split(separator: ".", omittingEmptySubsequences: false)
    #expect(await check("\(parts[0]).\(parts[1]).") == .idToken("signature"))
    // Payload swapped after signing: signature no longer matches.
    let other = makeJWT(claims: ["sub": "user-2"]).split(separator: ".", omittingEmptySubsequences: false)
    #expect(await check("\(parts[0]).\(other[1]).\(parts[2])") == .idToken("signature"))
}

@Test func rejectsKeyThatIsNotRS256OrTooSmall() async {
    var es = keyA.jwk
    es.alg = "RS512"
    #expect(await check(makeJWT(), jwks: FakeJWKS([es])) == .idToken("key"))
    var ec = keyA.jwk
    ec.kty = "EC"
    #expect(await check(makeJWT(), jwks: FakeJWKS([ec])) == .idToken("key"))
    for e in ["AQ", "Ag", "AQAA", "AA", ""] {  // 1, 2, 65536, 0, empty
        var bad = keyA.jwk
        bad.e = e
        #expect(await check(makeJWT(), jwks: FakeJWKS([bad])) == .idToken("key"), "e=\(e)")
    }
    var three = keyA.jwk
    three.e = "Aw"  // 3 is acceptable; the signature then fails because it is the wrong key.
    #expect(await check(makeJWT(), jwks: FakeJWKS([three])) == .idToken("signature"))
    let weak = TestKey(kid: "k1", bits: 1024)
    #expect(await check(makeJWT(signer: weak), jwks: FakeJWKS([weak.jwk])) == .idToken("key"))
}

@Test func unknownKidRefetchesJWKSOnce() async throws {
    let provider = FakeJWKS([keyA.jwk], refreshed: [keyA.jwk, keyB.jwk])
    let jwt = makeJWT(header: ["alg": "RS256", "kid": "k2"], signer: keyB)
    let claims = try await validator(provider).validate(jwt, clientID: "oaiapp_1", nonce: "N")
    #expect(claims.subject == "user-1")
    #expect(provider.calls == 2 && provider.forced == 1)
}

@Test func knownKidDoesNotRefetch() async throws {
    let provider = FakeJWKS([keyA.jwk])
    _ = try await validator(provider).validate(makeJWT(), clientID: "oaiapp_1", nonce: "N")
    #expect(provider.calls == 1 && provider.forced == 0)
    #expect(await check(makeJWT(header: ["alg": "RS256", "kid": "zzz"]), jwks: provider) == .idToken("kid"))
    #expect(provider.calls == 3 && provider.forced == 1)
}

// MARK: - DER

@Test func derRoundTrip() throws {
    let parts = try #require(RSAPublicKeyDER.decode(keyA.publicDER))
    #expect(parts.modulus.count == 256 && parts.modulus.first != 0)
    #expect(parts.exponent == Data([0x01, 0x00, 0x01]))
    #expect(RSAPublicKeyDER.encode(modulus: parts.modulus, exponent: parts.exponent) == keyA.publicDER)
    // Leading zero bytes in the input are normalised away.
    #expect(RSAPublicKeyDER.encode(modulus: Data([0]) + parts.modulus, exponent: Data([0]) + parts.exponent) == keyA.publicDER)
}

@Test func base64URLRejectsStandardAlphabet() {
    #expect(Base64URL.decode("-_8") == Data([0xFB, 0xFF]))
    #expect(Base64URL.decode("+/8") == nil)
    #expect(Base64URL.decode("ab+c") == nil && Base64URL.decode("ab/c") == nil && Base64URL.decode("YQ==") == nil)
}

@Test func derSmallValuesAndGarbage() {
    let der = RSAPublicKeyDER.encode(modulus: Data([0x80]), exponent: Data([0x03]))
    #expect(der == Data([0x30, 0x07, 0x02, 0x02, 0x00, 0x80, 0x02, 0x01, 0x03]))
    #expect(RSAPublicKeyDER.decode(der)?.modulus == Data([0x80]))
    #expect(RSAPublicKeyDER.decode(Data([0x30, 0x05, 0x02])) == nil)
    #expect(RSAPublicKeyDER.decode(Data()) == nil)
    #expect(RSAPublicKeyDER.decode(der + Data([0x00])) == nil)
}

// MARK: - URLJWKSProvider

private final class FakeFetch: Sendable {
    let calls = Mutex<[URLRequest]>([])
    let response: Mutex<(status: Int, body: Data)>
    init(status: Int = 200, body: Data) { response = Mutex((status, body)) }
    var count: Int { calls.withLock { $0.count } }
    func set(status: Int, body: Data = Data()) { response.withLock { $0 = (status, body) } }
    func fetch(_ r: URLRequest) async throws -> (Data, HTTPURLResponse) {
        calls.withLock { $0.append(r) }
        let (status, body) = response.withLock { $0 }
        return (body, HTTPURLResponse(url: r.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private let jwksBody: Data = {
    let rsa: [String: Any] = ["kid": "k1", "kty": "RSA", "alg": "RS256", "use": "sig", "n": keyA.jwk.n, "e": keyA.jwk.e]
    let ec: [String: Any] = ["kid": "e1", "kty": "EC", "crv": "P-256", "x": "AA", "y": "BB"]
    let enc: [String: Any] = ["kid": "x1", "kty": "RSA", "use": "enc", "n": keyB.jwk.n, "e": keyB.jwk.e]
    return try! JSONSerialization.data(withJSONObject: ["keys": [rsa, ec, enc]])
}()

@Test func urlJWKSProviderFetchesCachesAndSkipsNonRSA() async throws {
    let fake = FakeFetch(body: jwksBody)
    let clock = Mutex(now)
    let provider = URLJWKSProvider(fetch: { try await fake.fetch($0) }, now: { clock.withLock { $0 } })
    let keys = try await provider.keys(forceRefresh: false)
    #expect(keys.map(\.kid) == ["k1"] && keys.first?.n == keyA.jwk.n)
    _ = try await provider.keys(forceRefresh: false)
    #expect(fake.calls.withLock { $0.count } == 1)
    let request = try #require(fake.calls.withLock { $0.first })
    #expect(request.url == SIWC.jwksURL && request.httpMethod == "GET")
    // A forced refetch within 60 s of the last fetch is served from the cache.
    clock.withLock { $0 = $0.addingTimeInterval(59) }
    _ = try await provider.keys(forceRefresh: true)
    #expect(fake.count == 1)
    clock.withLock { $0 = $0.addingTimeInterval(2) }
    _ = try await provider.keys(forceRefresh: true)
    #expect(fake.calls.withLock { $0.count } == 2)
    _ = try await provider.keys(forceRefresh: true)
    #expect(fake.count == 2)
    clock.withLock { $0 = $0.addingTimeInterval(23 * 3600) }
    _ = try await provider.keys(forceRefresh: false)
    #expect(fake.calls.withLock { $0.count } == 2)
    clock.withLock { $0 = $0.addingTimeInterval(2 * 3600) }
    _ = try await provider.keys(forceRefresh: false)
    #expect(fake.calls.withLock { $0.count } == 3)
}

@Test func urlJWKSProviderRejectsBadResponses() async {
    let failing = URLJWKSProvider(fetch: { try await FakeFetch(status: 503, body: Data()).fetch($0) })
    await #expect(throws: AuthError.idToken("jwks")) { try await failing.keys(forceRefresh: false) }
    let garbage = URLJWKSProvider(fetch: { try await FakeFetch(body: Data("nope".utf8)).fetch($0) })
    await #expect(throws: AuthError.idToken("jwks")) { try await garbage.keys(forceRefresh: false) }
}

@Test func urlJWKSProviderServesStaleKeysWhenRefetchFails() async throws {
    let fake = FakeFetch(body: jwksBody)
    let clock = Mutex(now)
    let provider = URLJWKSProvider(fetch: { try await fake.fetch($0) }, now: { clock.withLock { $0 } })
    _ = try await provider.keys(forceRefresh: false)
    fake.set(status: 503)
    clock.withLock { $0 = $0.addingTimeInterval(25 * 3600) }
    #expect(try await provider.keys(forceRefresh: false).map(\.kid) == ["k1"])
    #expect(fake.count == 2)
    clock.withLock { $0 = $0.addingTimeInterval(120) }
    #expect(try await provider.keys(forceRefresh: true).map(\.kid) == ["k1"])
    #expect(fake.count == 3)
    // Recovery: the next successful fetch replaces the stale set.
    fake.set(status: 200, body: jwksBody)
    clock.withLock { $0 = $0.addingTimeInterval(120) }
    _ = try await provider.keys(forceRefresh: false)
    #expect(fake.count == 4)
    _ = try await provider.keys(forceRefresh: false)
    #expect(fake.count == 4)
}

@Test func urlJWKSProviderDoesNotServeVeryOldKeys() async throws {
    let fake = FakeFetch(body: jwksBody)
    let clock = Mutex(now)
    let provider = URLJWKSProvider(fetch: { try await fake.fetch($0) }, now: { clock.withLock { $0 } })
    _ = try await provider.keys(forceRefresh: false)
    fake.set(status: 503)
    clock.withLock { $0 = $0.addingTimeInterval(URLJWKSProvider.maxStaleness + 1) }
    await #expect(throws: AuthError.idToken("jwks")) { try await provider.keys(forceRefresh: false) }
}
