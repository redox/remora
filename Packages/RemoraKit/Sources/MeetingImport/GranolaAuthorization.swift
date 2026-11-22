import Foundation
import LLM
import Security

/// Granola's public-client OAuth. The two origins are fixed so discovery or
/// redirects cannot move the credential exchange to a third-party host.
public actor GranolaAuthorization {
    private struct ClientRegistration: Decodable { let client_id: String }

    private struct Tokens: Codable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int?
        let token_type: String
    }

    private struct Credential: Codable {
        let clientID: String
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date
    }

    private static let issuer = URL(string: "https://mcp-auth.granola.ai")!
    private static let registration = issuer.appending(path: "oauth2/register")
    private static let authorization = issuer.appending(path: "oauth2/authorize")
    private static let exchange = issuer.appending(path: "oauth2/token")
    private let browser: any BrowserOpening
    private var cached: Credential?
    private var isSigningIn = false
    private var epoch = 0

    public init(browser: any BrowserOpening) { self.browser = browser }

    public func signIn() async throws {
        guard !isSigningIn else { throw MeetingImportError.signInFailed }
        isSigningIn = true
        defer { isSigningIn = false }
        let epoch = self.epoch
        let listener = LoopbackServer(ports: [])
        defer { listener.stop() }
        let port = try await listener.start()
        let redirect = "http://127.0.0.1:\(port)/auth/callback"
        let registration: ClientRegistration = try await Self.post(Self.registration, json: [
            "client_name": "Remora",
            "redirect_uris": [redirect],
            "token_endpoint_auth_method": "none",
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
        ])
        let pkce = LLM.PKCE.make()
        let state = RandomToken.make()
        var url = URLComponents(url: Self.authorization, resolvingAgainstBaseURL: false)!
        url.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: registration.client_id),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "scope", value: "mcp"),
            .init(name: "resource", value: MeetingEndpoint.granola),
        ]
        guard let location = url.url, browser.open(location) else { throw MeetingImportError.signInFailed }
        let callback = try await listener.waitForCallback(timeout: .seconds(180))
        guard callback["state"] == state, callback["error"] == nil,
              callback["iss"].map({ $0 == Self.issuer.absoluteString }) ?? true,
              let code = callback["code"], !code.isEmpty else { throw MeetingImportError.signInFailed }
        let tokens = try await Self.exchange([
            "grant_type": "authorization_code", "client_id": registration.client_id, "code": code,
            "redirect_uri": redirect, "code_verifier": pkce.verifier, "resource": MeetingEndpoint.granola,
        ])
        try Task.checkCancellation()
        guard epoch == self.epoch else { throw CancellationError() }
        try persist(Self.credential(tokens, clientID: registration.client_id))
        self.epoch &+= 1
        listener.finish(signedIn: true)
    }

    func token(forceRefresh: Bool = false) async throws -> String {
        guard let credential = try cached ?? Self.load() else { throw MeetingImportError.signInRequired }
        if !forceRefresh, credential.expiresAt.timeIntervalSinceNow > 60 {
            cached = credential
            return credential.accessToken
        }
        guard let refresh = credential.refreshToken else { throw MeetingImportError.signInRequired }
        let epoch = self.epoch
        let tokens: Tokens
        do {
            tokens = try await Self.exchange([
                "grant_type": "refresh_token", "client_id": credential.clientID, "refresh_token": refresh,
                "resource": MeetingEndpoint.granola,
            ])
        } catch MeetingImportError.httpStatus(400) {
            throw MeetingImportError.signInRequired
        } catch MeetingImportError.httpStatus(401) {
            throw MeetingImportError.signInRequired
        }
        try Task.checkCancellation()
        guard epoch == self.epoch else { throw CancellationError() }
        let next = try Self.credential(tokens, clientID: credential.clientID, previousRefresh: refresh)
        try persist(next)
        return next.accessToken
    }

    public func disconnect() throws {
        epoch &+= 1
        cached = nil
        let status = SecItemDelete(Self.keychainQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MeetingImportError.signInFailed }
    }

    private func persist(_ credential: Credential) throws {
        let data = try JSONEncoder().encode(credential)
        let update = [kSecValueData as String: data]
        var result = SecItemUpdate(Self.keychainQuery as CFDictionary, update as CFDictionary)
        if result == errSecItemNotFound {
            var query = Self.keychainQuery
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            result = SecItemAdd(query as CFDictionary, nil)
        }
        guard result == errSecSuccess else { throw MeetingImportError.signInFailed }
        cached = credential
    }

    private static var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dev.remora.meeting-import",
         kSecAttrAccount as String: "granola"]
    }

    private static func load() throws -> Credential? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw MeetingImportError.signInRequired }
        return try JSONDecoder().decode(Credential.self, from: data)
    }

    private static func credential(_ tokens: Tokens, clientID: String, previousRefresh: String? = nil) throws -> Credential {
        guard tokens.token_type.caseInsensitiveCompare("Bearer") == .orderedSame,
              tokens.access_token.wholeMatch(of: /[A-Za-z0-9._~+\/-]+=*/) != nil else {
            throw MeetingImportError.signInFailed
        }
        return Credential(clientID: clientID, accessToken: tokens.access_token,
                          refreshToken: tokens.refresh_token ?? previousRefresh,
                          expiresAt: Date().addingTimeInterval(Double(tokens.expires_in ?? 3600)))
    }

    private static func post<T: Decodable>(_ url: URL, json: [String: Any]) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        return try await post(request)
    }

    private static func exchange(_ fields: [String: String]) async throws -> Tokens {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let body = fields.map { key, value in
            key + "=" + (value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")
        }.joined(separator: "&")
        var request = URLRequest(url: exchange)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        return try await post(request)
    }

    private static func post<T: Decodable>(_ request: URLRequest) async throws -> T {
        var request = request
        request.httpMethod = "POST"
        let session = MeetingHTTPSession.make()
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MeetingImportError.signInFailed }
        guard (200..<300).contains(http.statusCode) else { throw MeetingImportError.httpStatus(http.statusCode) }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
