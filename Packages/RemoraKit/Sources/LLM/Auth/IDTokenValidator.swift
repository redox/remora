import Foundation
import Security

/// One RSA signing key from the issuer's JWKS.
public struct JWK: Codable, Sendable, Equatable {
    public var kid: String
    public var kty: String
    public var alg: String?
    public var n: String
    public var e: String

    public init(kid: String, kty: String, alg: String?, n: String, e: String) {
        self.kid = kid
        self.kty = kty
        self.alg = alg
        self.n = n
        self.e = e
    }

    /// Smallest accepted RSA modulus.
    static let minimumModulusBits = 2048

    /// An in-memory RSA public key (`SecKeyCreateWithData`; nothing is stored in a keychain).
    func publicKey() throws -> SecKey {
        guard kty == "RSA", alg == nil || alg == "RS256",
              let modulus = Base64URL.decode(n), let exponent = Base64URL.decode(e) else {
            throw AuthError.idToken("key")
        }
        let significant = modulus.drop(while: { $0 == 0 })
        let e = exponent.drop(while: { $0 == 0 })
        // The exponent must be odd and at least 3 (rejects e = 1, which makes "signatures" trivial, and even values).
        guard significant.count * 8 >= Self.minimumModulusBits, let last = e.last, last & 1 == 1,
              e.count > 1 || last >= 3 else {
            throw AuthError.idToken("key")
        }
        let der = RSAPublicKeyDER.encode(modulus: modulus, exponent: exponent)
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: significant.count * 8,
        ]
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil) else {
            throw AuthError.idToken("key")
        }
        return key
    }
}

public protocol JWKSProviding: Sendable {
    func keys(forceRefresh: Bool) async throws -> [JWK]
}

public struct IDTokenClaims: Sendable, Equatable {
    public let subject: String
    public let email: String?
    public let expiresAt: Date

    public init(subject: String, email: String?, expiresAt: Date) {
        self.subject = subject
        self.email = email
        self.expiresAt = expiresAt
    }
}

extension IDTokenClaims: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private var redactedFields: KeyValuePairs<String, Any> {
        ["subject": Redacted.secret(subject), "email": Redacted.secret(email), "expiresAt": expiresAt]
    }
    public var description: String { Redacted.describe("IDTokenClaims", redactedFields) }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: redactedFields, displayStyle: .struct) }
}

/// Validates a SIWC ID token: RS256 signature against the issuer's JWKS, then iss, aud, exp, iat, nonce, sub.
/// Failures throw `AuthError.idToken(<check name>)`; token contents never appear in errors.
public struct IDTokenValidator: Sendable {
    private let jwks: any JWKSProviding
    private let leeway: TimeInterval
    private let now: @Sendable () -> Date

    public init(jwks: any JWKSProviding, leeway: TimeInterval = 60, now: @escaping @Sendable () -> Date = Date.init) {
        self.jwks = jwks
        self.leeway = leeway
        self.now = now
    }

    private struct Header: Decodable {
        let alg: String
        let kid: String?
    }

    private enum Audience: Decodable {
        case one(String), many([String])
        init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .one(s) } else { self = .many(try c.decode([String].self)) }
        }
        func contains(_ id: String) -> Bool {
            switch self {
            case .one(let s): return s == id
            case .many(let a): return a.contains(id)
            }
        }
    }

    private struct Claims: Decodable {
        let iss: String?
        let sub: String?
        let aud: Audience?
        let exp: Double?
        let iat: Double?
        let nonce: String?
        let email: String?
    }

    /// `nonce` is the attempt's nonce at sign-in; refresh-time ID tokens pass `nil`.
    public func validate(_ jwt: String, clientID: String, nonce: String?) async throws -> IDTokenClaims {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw AuthError.idToken("format") }
        guard let headerData = Base64URL.decode(parts[0]),
              let header = try? JSONDecoder().decode(Header.self, from: headerData) else {
            throw AuthError.idToken("header")
        }
        // Only RS256: rejects `none`, HS* (key confusion) and anything else.
        guard header.alg == "RS256" else { throw AuthError.idToken("alg") }
        guard let kid = header.kid, !kid.isEmpty else { throw AuthError.idToken("kid") }
        guard let signature = Base64URL.decode(parts[2]), !signature.isEmpty else { throw AuthError.idToken("signature") }

        let key = try await signingKey(kid: kid).publicKey()
        let signedInput = Data("\(parts[0]).\(parts[1])".utf8)
        guard SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, signedInput as CFData, signature as CFData, nil) else {
            throw AuthError.idToken("signature")
        }

        guard let payload = Base64URL.decode(parts[1]),
              let claims = try? JSONDecoder().decode(Claims.self, from: payload) else {
            throw AuthError.idToken("claims")
        }
        let current = now()
        guard claims.iss == SIWC.issuer else { throw AuthError.idToken("iss") }
        guard claims.aud?.contains(clientID) == true else { throw AuthError.idToken("aud") }
        guard let exp = claims.exp, exp > current.timeIntervalSince1970 - leeway else { throw AuthError.idToken("exp") }
        guard let iat = claims.iat, iat <= current.timeIntervalSince1970 + leeway else { throw AuthError.idToken("iat") }
        if let nonce, claims.nonce != nonce { throw AuthError.idToken("nonce") }
        guard let sub = claims.sub, !sub.isEmpty else { throw AuthError.idToken("sub") }
        return IDTokenClaims(subject: sub, email: claims.email, expiresAt: Date(timeIntervalSince1970: exp))
    }

    /// The `sub` claim **without** verifying anything. Only for comparing a refresh-time ID token,
    /// delivered over TLS by the token endpoint, with the stored subject when the keys are unavailable.
    static func unverifiedSubject(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let payload = Base64URL.decode(parts[1]),
              let claims = try? JSONDecoder().decode(Claims.self, from: payload),
              let sub = claims.sub, !sub.isEmpty else { return nil }
        return sub
    }

    /// Looks the key up in the cached JWKS; on a miss refetches once (key rotation).
    private func signingKey(kid: String) async throws -> JWK {
        if let k = try await jwks.keys(forceRefresh: false).first(where: { $0.kid == kid }) { return k }
        if let k = try await jwks.keys(forceRefresh: true).first(where: { $0.kid == kid }) { return k }
        throw AuthError.idToken("kid")
    }
}

/// Fetches `SIWC.jwksURL` and caches the RSA signing keys for 24 hours. Concurrent callers share one
/// fetch. A forced refetch (unknown `kid`) within `minimumRefetchInterval` of the last fetch is served
/// from the cache, so bogus `kid`s cannot hammer the endpoint. If a fetch fails, keys no older than
/// `maxStaleness` are served instead of failing.
public actor URLJWKSProvider: JWKSProviding {
    public static let cacheLifetime: TimeInterval = 24 * 3600
    public static let maxStaleness: TimeInterval = 7 * 24 * 3600
    public static let minimumRefetchInterval: TimeInterval = 60

    private let fetch: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let now: @Sendable () -> Date
    private var cached: (keys: [JWK], fetchedAt: Date)?
    private var lastAttempt: Date?
    private var inFlight: Task<[JWK], any Error>?

    public init(fetch: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse),
                now: @escaping @Sendable () -> Date = Date.init) {
        self.fetch = fetch
        self.now = now
    }

    public func keys(forceRefresh: Bool) async throws -> [JWK] {
        let current = now()
        if let cached {
            let age = current.timeIntervalSince(cached.fetchedAt)
            if !forceRefresh, age < Self.cacheLifetime { return cached.keys }
            if forceRefresh, age < Self.cacheLifetime, let lastAttempt,
               current.timeIntervalSince(lastAttempt) < Self.minimumRefetchInterval {
                return cached.keys
            }
        }
        if let inFlight { return try await inFlight.value }
        let fetch = self.fetch
        let task = Task { try await Self.load(fetch) }
        inFlight = task
        lastAttempt = current
        defer { inFlight = nil }
        do {
            let keys = try await task.value
            cached = (keys, now())
            return keys
        } catch {
            if let cached, now().timeIntervalSince(cached.fetchedAt) < Self.maxStaleness { return cached.keys }
            throw error
        }
    }

    private struct Entry: Decodable {
        let kid: String?
        let kty: String?
        let alg: String?
        let n: String?
        let e: String?
        let use: String?
    }

    private struct KeySet: Decodable {
        let keys: [Entry]
    }

    private static func load(_ fetch: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) async throws -> [JWK] {
        var request = URLRequest(url: SIWC.jwksURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await fetch(request)
        guard response.statusCode == 200, let set = try? JSONDecoder().decode(KeySet.self, from: data) else {
            throw AuthError.idToken("jwks")
        }
        return set.keys.compactMap { e in
            guard let kid = e.kid, e.kty == "RSA", e.use == nil || e.use == "sig", let n = e.n, let ex = e.e else { return nil }
            return JWK(kid: kid, kty: "RSA", alg: e.alg, n: n, e: ex)
        }
    }
}
