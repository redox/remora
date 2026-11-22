import Foundation
import LLMTestSupport
import Security
import Synchronization
@testable import LLM

// Shared fixtures for the SIWC session tests (sign-in flow, token manager). In-memory RSA keys only;
// nothing touches the Keychain, and the only sockets are loopback listeners on 127.0.0.1.

struct FxKey: @unchecked Sendable {
    let privateKey: SecKey
    let jwk: JWK

    init(kid: String) {
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecAttrIsPermanent as String: false,
            kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: false],
        ]
        var error: Unmanaged<CFError>?
        privateKey = SecKeyCreateRandomKey(attrs as CFDictionary, &error)!
        let der = SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(privateKey)!, &error)! as Data
        let parts = RSAPublicKeyDER.decode(der)!
        jwk = JWK(kid: kid, kty: "RSA", alg: "RS256", n: Base64URL.encode(parts.modulus), e: Base64URL.encode(parts.exponent))
    }

    func sign(_ input: Data) -> Data {
        var error: Unmanaged<CFError>?
        return SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, input as CFData, &error)! as Data
    }
}

final class FxJWKS: JWKSProviding {
    private let onFetch: @Sendable () throws -> Void

    /// `onFetch` runs on every key lookup (to probe state, or to throw like an unreachable JWKS).
    init(onFetch: @escaping @Sendable () throws -> Void = {}) { self.onFetch = onFetch }

    func keys(forceRefresh: Bool) async throws -> [JWK] {
        try onFetch()
        return [Fx.key.jwk]
    }
}

enum Fx {
    static let key = FxKey(kid: "fx-k1")
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let tokenPath = SIWC.tokenURL.path

    static func idToken(sub: String = "user-1", aud: String = "oaiapp_1", nonce: String? = nil,
                        email: String? = "a@b.c", now: Date = t0, signer: FxKey = key) -> String {
        var claims: [String: Any] = [
            "iss": SIWC.issuer, "aud": [aud], "sub": sub,
            "exp": now.timeIntervalSince1970 + 3600, "iat": now.timeIntervalSince1970 - 5,
        ]
        if let nonce { claims["nonce"] = nonce }
        if let email { claims["email"] = email }
        func part(_ o: [String: Any]) -> String {
            Base64URL.encode(try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]))
        }
        let input = "\(part(["alg": "RS256", "kid": key.jwk.kid, "typ": "JWT"])).\(part(claims))"
        return "\(input).\(Base64URL.encode(signer.sign(Data(input.utf8))))"
    }

    static func validator(now: Date = t0, jwks: FxJWKS = FxJWKS()) -> IDTokenValidator {
        IDTokenValidator(jwks: jwks, now: { now })
    }

    static func tokenResponse(access: String = "at-2", refresh: String? = "rt-2", id: String?,
                              scope: String? = SIWC.scopes.joined(separator: " "), expiresIn: Int = 3600,
                              earliest: Double? = nil) -> FakeHTTPResponse {
        var o: [String: Any] = ["access_token": access, "token_type": "Bearer", "expires_in": expiresIn]
        if let refresh { o["refresh_token"] = refresh }
        if let id { o["id_token"] = id }
        if let scope { o["scope"] = scope }
        if let earliest { o["earliest_refresh_at"] = String(Int(earliest)) }
        return .json(200, o)
    }

    static func tokens(access: String = "at-1", refresh: String? = "rt-1", idToken: String = "id-old",
                       expiresAt: Date, earliest: Date? = nil, scopes: [String] = SIWC.scopes,
                       sub: String = "user-1", email: String? = "a@b.c") -> SIWCTokens {
        SIWCTokens(idToken: idToken, accessToken: access, refreshToken: refresh, expiresAt: expiresAt,
                   earliestRefreshAt: earliest, scopes: scopes, subject: sub, email: email)
    }

    static func account(clientID: String? = "oaiapp_1", tokens: SIWCTokens?, hint: SIWCHint? = nil) -> SIWCAccount {
        SIWCAccount(registration: .init(hostID: "urn:uuid:00000000-0000-4000-8000-000000000001", clientID: clientID),
                    tokens: tokens, hint: hint)
    }

    static func query(_ url: URL) -> [String: String] {
        var q: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { q[item.name] = item.value ?? "" }
        return q
    }

    /// A non-caching session for talking to the loopback listener.
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    static func get(_ url: String) async throws -> (status: Int, body: String) {
        let (d, r) = try await session.data(from: URL(string: url)!)
        return ((r as! HTTPURLResponse).statusCode, String(decoding: d, as: UTF8.self))
    }
}

extension SIWCTokens {
    /// Issued at 0 (epoch), `expiresAt`/`earliest` in seconds since 1970.
    static func fixture(expiresAt: Double, earliest: Double?) -> SIWCTokens {
        Fx.tokens(expiresAt: Date(timeIntervalSince1970: expiresAt), earliest: earliest.map { Date(timeIntervalSince1970: $0) })
    }
}

/// Plays the system browser: records the authorize URL, then (asynchronously, like a real browser)
/// hits the stray paths and the redirect URI with the callback query built from the authorize query.
final class FakeBrowser: BrowserOpening {
    private struct State {
        var urls: [URL] = []
        var pages: [String] = []
    }

    private let state = Mutex(State())
    private let opens: Bool
    private let strays: [String]
    private let callback: @Sendable ([String: String]) -> [String: String]?

    init(opens: Bool = true, strays: [String] = [], callback: @escaping @Sendable ([String: String]) -> [String: String]?) {
        self.opens = opens
        self.strays = strays
        self.callback = callback
    }

    /// The standard callback: same state, `code=c`, optional issued client id and extras.
    static func approving(clientID: String? = "oaiapp_1", extra: [String: String] = [:], removing: [String] = [],
                          strays: [String] = []) -> FakeBrowser {
        FakeBrowser(strays: strays) { q in
            var cb = ["code": "c", "state": q["state"] ?? "", "iss": SIWC.issuer, "scope": SIWC.scopes.joined(separator: " ")]
            if let clientID { cb["client_id"] = clientID }
            for (k, v) in extra { cb[k] = v }
            for k in removing { cb[k] = nil }
            return cb
        }
    }

    var urls: [URL] { state.withLock { $0.urls } }
    var authorizeQuery: [String: String] { urls.last.map(Fx.query) ?? [:] }

    /// The page served for the callback, once the browser has received it.
    func callbackPage() async -> String? {
        for _ in 0..<300 {
            if let p = state.withLock({ $0.pages.first }) { return p }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    func open(_ url: URL) -> Bool {
        state.withLock { $0.urls.append(url) }
        guard opens else { return false }
        let q = Fx.query(url)
        guard let cb = callback(q), let redirect = q["redirect_uri"], var comps = URLComponents(string: redirect) else { return true }
        comps.queryItems = cb.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        let target = comps.url!
        let base = "\(comps.scheme!)://\(comps.host!):\(comps.port!)"
        let strays = self.strays
        Task.detached { [self] in
            for s in strays { _ = try? await Fx.get(base + s) }
            if let (_, body) = try? await Fx.get(target.absoluteString) {
                self.state.withLock { $0.pages.append(body) }
            }
        }
        return true
    }
}

/// Records every save; can be told to fail saves.
final class SpyStore: CredentialStore {
    private struct State {
        var account: SIWCAccount?
        var saves: [SIWCAccount] = []
        var failSaves = false
    }

    private let state: Mutex<State>

    init(_ initial: SIWCAccount?) { state = Mutex(State(account: initial)) }

    var saves: [SIWCAccount] { state.withLock { $0.saves } }
    var stored: SIWCAccount? { state.withLock { $0.account } }
    func setFailSaves(_ f: Bool) { state.withLock { $0.failSaves = f } }

    struct SaveFailed: Error {}

    func load() throws -> SIWCAccount? { state.withLock { $0.account } }
    func save(_ a: SIWCAccount) throws {
        try state.withLock {
            if $0.failSaves { throw SaveFailed() }
            $0.account = a
            $0.saves.append(a)
        }
    }
    func delete() throws { state.withLock { $0.account = nil } }
}
