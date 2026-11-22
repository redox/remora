// Throwaway spike: Sign in with ChatGPT (open-source / local app flow) harness.
// Subcommands: authorize-url, login, models, ask, probe, refresh.
import AppKit
import CryptoKit
import Foundation
import Network

// MARK: - Constants

let authBase = "https://auth.openai.com"
let authorizeEndpoint = "\(authBase)/api/accounts/authorize"
let tokenEndpoint = "\(authBase)/api/accounts/oauth/token"
let apiBase = "https://api.openai.com/v1"
let dynamicClientID = "dynamic_agent_client"
let agentName = "Remora"
let requestedScopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
let requiredScope = "chatgpt.tokens.use.direct"
let preferredPort: UInt16 = 1455
let callbackPath = "/auth/callback"

let configDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/remora-spike")
let hostFile = configDir.appendingPathComponent("host.json")
let credsFile = configDir.appendingPathComponent("credentials.json")

// MARK: - Utilities

func out(_ s: String) { print(s); fflush(stdout) }
func fail(_ s: String) -> Never { out(s); exit(1) }

func b64url(_ d: Data) -> String {
    d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

func randomToken(_ bytes: Int = 32) -> String {
    var g = SystemRandomNumberGenerator()
    return b64url(Data((0..<bytes).map { _ in UInt8.random(in: 0...255, using: &g) }))
}

func pkceChallenge(_ verifier: String) -> String {
    b64url(Data(SHA256.hash(data: Data(verifier.utf8))))
}

let unreserved: CharacterSet = {
    var c = CharacterSet.alphanumerics
    c.insert(charactersIn: "-._~")
    return c
}()
func pct(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s }
func formEncode(_ pairs: [(String, String)]) -> String { pairs.map { "\(pct($0.0))=\(pct($0.1))" }.joined(separator: "&") }

func ensureConfigDir() {
    try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: configDir.path)
}

/// Atomic write with 0600: temp file created 0600 in same dir, then rename.
func writeSecure(_ data: Data, to url: URL) throws {
    ensureConfigDir()
    let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
        throw NSError(domain: "siwc", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot create temp file"])
    }
    if rename(tmp.path, url.path) != 0 {
        try? FileManager.default.removeItem(at: tmp)
        throw NSError(domain: "siwc", code: 2, userInfo: [NSLocalizedDescriptionKey: "rename failed errno \(errno)"])
    }
}

func jwtClaims(_ jwt: String) -> [String: Any]? {
    let parts = jwt.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var s = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while s.count % 4 != 0 { s += "=" }
    guard let d = Data(base64Encoded: s), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
    return o
}

// MARK: - Host id & credentials

struct HostFile: Codable { var ext_agent_host_id: String }

func loadOrCreateHostID() -> String {
    if let d = try? Data(contentsOf: hostFile), let h = try? JSONDecoder().decode(HostFile.self, from: d) {
        return h.ext_agent_host_id
    }
    let id = "urn:uuid:\(UUID().uuidString.lowercased())"
    if let d = try? JSONEncoder().encode(HostFile(ext_agent_host_id: id)) { try? writeSecure(d, to: hostFile) }
    return id
}

struct Credentials: Codable {
    var email: String?
    var issuer: String
    var subject: String
    var client_id: String
    var ext_agent_host_id: String
    var id_token: String
    var access_token: String
    var refresh_token: String?
    var token_type: String
    var expires_in: Int
    var scopes: [String]
    var saved_at: String
    var earliest_refresh_at: String?
}

func loadCreds() -> Credentials? {
    guard let d = try? Data(contentsOf: credsFile) else { return nil }
    return try? JSONDecoder().decode(Credentials.self, from: d)
}

func saveCreds(_ c: Credentials) throws {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try writeSecure(try enc.encode(c), to: credsFile)
}

func isoString(_ d: Date) -> String { d.formatted(.iso8601) }
func isoDate(_ s: String) -> Date? { try? Date(s, strategy: .iso8601) }

// MARK: - Authorization URL

struct AuthAttempt {
    let state: String
    let nonce: String
    let verifier: String
    let redirectURI: String
    let clientID: String
    let url: String
    let redactedURL: String
}

func buildAttempt(port: UInt16, state: String = randomToken(24), nonce: String = randomToken(24),
                  verifier: String = randomToken(48)) -> AuthAttempt {
    let creds = loadCreds()
    let clientID = creds?.client_id ?? dynamicClientID
    let redirect = "http://127.0.0.1:\(port)\(callbackPath)"
    var pairs: [(String, String)] = [
        ("response_type", "code"),
        ("client_id", clientID),
        ("redirect_uri", redirect),
        ("scope", requestedScopes),
        ("resource", apiBase),
        ("state", state),
        ("nonce", nonce),
        ("code_challenge", pkceChallenge(verifier)),
        ("code_challenge_method", "S256"),
        ("ext_agent_host_id", loadOrCreateHostID()),
    ]
    if clientID == dynamicClientID { pairs.append(("agent_name_hint", agentName)) }
    else {
        if let t = creds?.id_token, !t.isEmpty { pairs.append(("id_token_hint", t)) }
        if let e = creds?.email, !e.isEmpty { pairs.append(("login_hint", e)) }
    }
    let url = "\(authorizeEndpoint)?\(formEncode(pairs))"
    let red = "\(authorizeEndpoint)?\(formEncode(pairs.map { $0.0 == "id_token_hint" ? ($0.0, "<redacted>") : $0 }))"
    return AuthAttempt(state: state, nonce: nonce, verifier: verifier, redirectURI: redirect, clientID: clientID,
                       url: url, redactedURL: red)
}

// MARK: - Loopback listener

final class CallbackServer: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: NWListener?
    private var continuation: CheckedContinuation<[String: String]?, Never>?
    private var result: [String: String]??
    private(set) var port: UInt16 = 0

    private func finish(_ r: [String: String]?) {
        lock.lock()
        if let c = continuation { continuation = nil; lock.unlock(); c.resume(returning: r) }
        else { if result == nil { result = .some(r) }; lock.unlock() }
    }

    /// Try preferred port on 127.0.0.1, fall back to an ephemeral port.
    func start() async throws -> UInt16 {
        for candidate in [preferredPort, 0] {
            do { return try await startOn(candidate) } catch { continue }
        }
        throw NSError(domain: "siwc", code: 3, userInfo: [NSLocalizedDescriptionKey: "cannot bind loopback listener"])
    }

    private func startOn(_ p: UInt16) async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: p)!)
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        let ready: UInt16 = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            let once = OnceBox()
            l.stateUpdateHandler = { st in
                switch st {
                case .ready: if once.take() { cont.resume(returning: l.port?.rawValue ?? p) }
                case .failed(let e): if once.take() { cont.resume(throwing: e) }
                case .cancelled: if once.take() { cont.resume(throwing: CancellationError()) }
                default: break
                }
            }
            l.start(queue: .global())
        }
        listener = l
        port = ready
        return ready
    }

    func wait(timeout: TimeInterval) async -> [String: String]? {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            self?.finish(nil)
        }
        let r: [String: String]? = await withCheckedContinuation { (c: CheckedContinuation<[String: String]?, Never>) in
            lock.lock()
            if let done = result { lock.unlock(); c.resume(returning: done) }
            else { continuation = c; lock.unlock() }
        }
        timer.cancel()
        return r
    }

    func stop() { listener?.cancel() }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global())
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self, let data, let text = String(data: data, encoding: .utf8) else { conn.cancel(); return }
            let line = text.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
            let comps = line.split(separator: " ")
            guard comps.count >= 2, let u = URLComponents(string: "http://x" + comps[1]), u.path == callbackPath else {
                self.respond(conn, status: "404 Not Found", body: "Not found")
                return
            }
            var q: [String: String] = [:]
            for item in u.queryItems ?? [] { q[item.name] = item.value ?? "" }
            let ok = q["code"] != nil && q["error"] == nil
            let html = "<!doctype html><meta charset=utf-8><title>Remora</title><body style=\"font-family:-apple-system,sans-serif;text-align:center;margin-top:20vh\"><h2>\(ok ? "Signed in" : "Sign-in failed")</h2><p>You can close this tab.</p></body>"
            self.respond(conn, status: "200 OK", body: html, html: true)
            self.finish(q)
        }
    }

    private func respond(_ conn: NWConnection, status: String, body: String, html: Bool = false) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(html ? "text/html" : "text/plain"); charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in conn.cancel() })
    }
}

final class OnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; if used { return false }; used = true; return true }
}

// MARK: - HTTP helpers

struct HTTPResult: Sendable { let status: Int; let body: Data }

func formPost(_ url: String, _ pairs: [(String, String)]) async throws -> HTTPResult {
    var r = URLRequest(url: URL(string: url)!)
    r.httpMethod = "POST"
    r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    r.httpBody = Data(formEncode(pairs).utf8)
    let (d, resp) = try await URLSession.shared.data(for: r)
    return HTTPResult(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, body: d)
}

func jsonObj(_ d: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] }
func snippet(_ d: Data, _ n: Int = 300) -> String { String(String(decoding: d, as: UTF8.self).prefix(n)) }

struct TokenResponse: Sendable {
    let access: String; let refresh: String?; let id: String?; let type: String
    let expiresIn: Int; let scope: String?; let earliest: String?
}

func parseTokens(_ r: HTTPResult) throws -> TokenResponse {
    guard r.status == 200, let o = jsonObj(r.body), let at = o["access_token"] as? String else {
        throw NSError(domain: "siwc", code: r.status, userInfo: [NSLocalizedDescriptionKey: "token endpoint HTTP \(r.status): \(r.status == 200 ? "200 body lacked access_token; keys=\((jsonObj(r.body)?.keys.sorted() ?? []).joined(separator: ","))" : snippet(r.body))"])
    }
    func s(_ k: String) -> String? {
        if let v = o[k] as? String { return v }
        if let v = o[k] as? NSNumber { return v.stringValue }
        return nil
    }
    return TokenResponse(access: at, refresh: o["refresh_token"] as? String, id: o["id_token"] as? String,
                         type: (o["token_type"] as? String) ?? "Bearer",
                         expiresIn: (o["expires_in"] as? Int) ?? 3600, scope: o["scope"] as? String,
                         earliest: s("earliest_refresh_at"))
}

// MARK: - Commands: authorize-url

func cmdAuthorizeURL() {
    let a = buildAttempt(port: preferredPort, state: "DUMMY_STATE", nonce: "DUMMY_NONCE", verifier: "DUMMY_VERIFIER_0123456789")
    out("host_id: \(loadOrCreateHostID())")
    out("client_id used: \(a.clientID)")
    out("redirect_uri: \(a.redirectURI)")
    out("code_verifier (dummy): DUMMY_VERIFIER_0123456789")
    out("URL:\n\(a.redactedURL)")
    if let u = URLComponents(string: a.url) {
        out("\nDecoded parameters:")
        for i in u.queryItems ?? [] { out("  \(i.name) = \(i.name == "id_token_hint" ? "<redacted>" : (i.value ?? ""))") }
    }
}

// MARK: - Commands: login

@MainActor func cmdLogin() async {
    let existing = loadCreds()
    let server = CallbackServer()
    let port: UInt16
    do { port = try await server.start() } catch { fail("LOGIN FAIL listener: \(error.localizedDescription)") }
    defer { server.stop() }
    let a = buildAttempt(port: port)
    out("Listening on \(a.redirectURI)")
    out("Authorization URL (open manually if browser does not launch):\n\(a.redactedURL)")
    if !NSWorkspace.shared.open(URL(string: a.url)!) { out("(NSWorkspace failed to open the URL; open it manually. Note redacted URL lacks id_token_hint.)") }
    out("Waiting up to 10 minutes for the callback...")
    guard let q = await server.wait(timeout: 600) else { fail("LOGIN FAIL timeout waiting for callback (10 min)") }
    if let e = q["error"] {
        guard q["state"] == a.state else { fail("LOGIN FAIL callback error=\(e) with mismatching state") }
        fail("LOGIN FAIL authorization error=\(e) \(q["error_description"] ?? "")")
    }
    guard q["state"] == a.state else { fail("LOGIN FAIL state mismatch") }
    guard let code = q["code"] else { fail("LOGIN FAIL no code in callback") }
    var clientID = a.clientID
    if clientID == dynamicClientID {
        guard let issued = q["client_id"], !issued.isEmpty, issued != dynamicClientID else {
            fail("LOGIN FAIL registration incomplete: callback had no issued client_id (params: \(q.keys.sorted()))")
        }
        clientID = issued
    } else if let c = q["client_id"], c != clientID {
        fail("LOGIN FAIL callback client_id \(c) differs from pending \(clientID)")
    }
    out("Callback OK (params: \(q.keys.sorted().joined(separator: ",")); issued client_id=\(clientID))")
    let tr: TokenResponse
    do {
        let res = try await formPost(tokenEndpoint, [
            ("grant_type", "authorization_code"), ("client_id", clientID), ("code", code),
            ("code_verifier", a.verifier), ("redirect_uri", a.redirectURI), ("resource", apiBase),
        ])
        tr = try parseTokens(res)
    } catch { fail("LOGIN FAIL token exchange: \((error as NSError).localizedDescription)") }
    guard let idt = tr.id, let claims = jwtClaims(idt) else { fail("LOGIN FAIL no/undecodable id_token") }
    var problems: [String] = []
    if (claims["iss"] as? String) != authBase { problems.append("iss=\(claims["iss"] ?? "nil")") }
    let aud: [String] = (claims["aud"] as? [String]) ?? ((claims["aud"] as? String).map { [$0] } ?? [])
    if !aud.contains(clientID) { problems.append("aud=\(aud)") }
    if (claims["nonce"] as? String) != a.nonce { problems.append("nonce mismatch") }
    if let exp = claims["exp"] as? Double { if exp <= Date().timeIntervalSince1970 { problems.append("expired") } } else { problems.append("no exp") }
    if !problems.isEmpty { fail("LOGIN FAIL id_token validation: \(problems.joined(separator: "; "))") }
    let sub = (claims["sub"] as? String) ?? ""
    if let ex = existing, ex.client_id == clientID, ex.subject != sub {
        fail("LOGIN FAIL identity mismatch with saved account; not replacing credentials")
    }
    let scopes = (tr.scope ?? q["scope"] ?? "").split(separator: " ").map(String.init)
    let creds = Credentials(email: claims["email"] as? String, issuer: authBase, subject: sub, client_id: clientID,
                            ext_agent_host_id: loadOrCreateHostID(), id_token: idt, access_token: tr.access,
                            refresh_token: tr.refresh, token_type: tr.type, expires_in: tr.expiresIn, scopes: scopes,
                            saved_at: isoString(Date()), earliest_refresh_at: tr.earliest)
    do { try saveCreds(creds) } catch { fail("LOGIN FAIL saving credentials: \(error)") }
    out("id_token claims keys: \(claims.keys.sorted().joined(separator: ","))  (signature NOT verified in spike)")
    out("access_token len=\(tr.access.count) expires_in=\(tr.expiresIn) refresh_token=\(tr.refresh == nil ? "absent" : "len=\(tr.refresh!.count)") earliest_refresh_at=\(tr.earliest ?? "n/a")")
    if let ac = jwtClaims(tr.access) { out("access_token claims keys: \(ac.keys.sorted().joined(separator: ","))") }
    out("LOGIN OK client_id=\(clientID) scopes=\(scopes.joined(separator: " "))")
    if !scopes.contains(requiredScope) { out("WARNING: granted scopes lack \(requiredScope); plan usage disabled") }
}

// MARK: - Refresh & token access

struct RefreshInfo { var rotated = false; var responseHadRefresh = false; var responseHadID = false }
nonisolated(unsafe) var lastRefreshInfo = RefreshInfo()

func doRefresh() async throws -> Credentials {
    guard var c = loadCreds() else { throw NSError(domain: "siwc", code: 0, userInfo: [NSLocalizedDescriptionKey: "no credentials; run login"]) }
    guard let rt = c.refresh_token else { throw NSError(domain: "siwc", code: 0, userInfo: [NSLocalizedDescriptionKey: "no refresh token saved"]) }
    let res = try await formPost(tokenEndpoint, [
        ("grant_type", "refresh_token"), ("client_id", c.client_id), ("refresh_token", rt), ("resource", apiBase),
    ])
    let tr = try parseTokens(res)
    c.access_token = tr.access
    lastRefreshInfo = RefreshInfo(rotated: tr.refresh != nil && tr.refresh != rt, responseHadRefresh: tr.refresh != nil, responseHadID: tr.id != nil)
    c.refresh_token = tr.refresh ?? c.refresh_token
    if let i = tr.id { c.id_token = i }
    c.expires_in = tr.expiresIn
    if let s = tr.scope { c.scopes = s.split(separator: " ").map(String.init) }
    c.saved_at = isoString(Date())
    c.earliest_refresh_at = tr.earliest
    try saveCreds(c)
    return c
}

func cmdRefresh() async {
    do {
        let c = try await doRefresh()
        out("REFRESH OK expires_in=\(c.expires_in) access_len=\(c.access_token.count) refresh_len=\(c.refresh_token?.count ?? 0) earliest_refresh_at=\(c.earliest_refresh_at ?? "n/a") response_had_refresh_token=\(lastRefreshInfo.responseHadRefresh) rotated=\(lastRefreshInfo.rotated) response_had_id_token=\(lastRefreshInfo.responseHadID) scopes=\(c.scopes.joined(separator: " "))")
    } catch { fail("REFRESH FAIL \((error as NSError).localizedDescription)") }
}

func accessToken() async -> String {
    guard var c = loadCreds() else { fail("no credentials; run login") }
    let saved = isoDate(c.saved_at) ?? .distantPast
    if saved.addingTimeInterval(Double(c.expires_in) - 120) < Date() {
        out("(access token near/after expiry; refreshing)")
        do { c = try await doRefresh() } catch { fail("refresh failed: \((error as NSError).localizedDescription)") }
    }
    return c.access_token
}

// MARK: - Models

struct ModelInfo: Sendable { let slug: String; let name: String; let visibility: String }

func fetchModels(_ token: String) async -> (Int, [ModelInfo], String) {
    var r = URLRequest(url: URL(string: "\(apiBase)/models")!)
    r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    do {
        let (d, resp) = try await URLSession.shared.data(for: r)
        let st = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard st == 200, let o = jsonObj(d), let arr = o["models"] as? [[String: Any]] else { return (st, [], snippet(d, 500)) }
        let ms = arr.map { ModelInfo(slug: ($0["slug"] as? String) ?? "?", name: ($0["display_name"] as? String) ?? "?",
                                     visibility: ($0["visibility"] as? String) ?? "?") }
        return (st, ms, "")
    } catch { return (0, [], "\(error)") }
}

func listed(_ ms: [ModelInfo]) -> [ModelInfo] { ms.filter { $0.visibility == "list" } }

func pickCheapest(_ ms: [ModelInfo]) -> ModelInfo? {
    let l = listed(ms)
    func has(_ m: ModelInfo, _ k: String) -> Bool { (m.slug + " " + m.name).lowercased().contains(k) }
    return l.first { has($0, "nano") } ?? l.first { has($0, "mini") } ?? l.first { has($0, "luna") } ?? l.first { has($0, "spark") } ?? l.first
}

func cmdModels() async {
    let t = await accessToken()
    let (st, ms, err) = await fetchModels(t)
    guard st == 200 else { fail("models HTTP \(st): \(err)") }
    out("HTTP 200, \(ms.count) models total; visibility=list:")
    for m in listed(ms) { out("  \(m.slug)\t\(m.name)") }
    let hidden = ms.filter { $0.visibility != "list" }
    if !hidden.isEmpty { out("non-listed: " + hidden.map { "\($0.slug)(\($0.visibility))" }.joined(separator: ", ")) }
    if let p = pickCheapest(ms) { out("cheapest-by-name-heuristic: \(p.slug)") }
}

// MARK: - Responses streaming

struct StreamResult: Sendable {
    var http = 0
    var errorCode: String?
    var errorMessage: String?
    var completed = false
    var failed = false
    var incomplete = false
    var text = ""
    var usageJSON: String?
    var eventTypes: [String] = []
    var raw: String = ""
    var ttft: Double?
    var toolCalls: [String] = []
    var total: Double = 0
}

func streamResponse(model: String, token: String, bodyExtra: Data?, echo: Bool, input: Data? = nil) async -> StreamResult {
    let t0 = Date()
    var r = await streamResponseInner(model: model, token: token, bodyExtra: bodyExtra, echo: echo, input: input)
    r.total = Date().timeIntervalSince(t0)
    return r
}

func streamResponseInner(model: String, token: String, bodyExtra: Data?, echo: Bool,
                    input: Data? = nil) async -> StreamResult {
    var body: [String: Any] = [
        "model": model, "instructions": "Reply in French.",
        "input": [["role": "user", "content": "Say hello in one short sentence."]],
        "store": false, "stream": true,
    ]
    if let input, let v = try? JSONSerialization.jsonObject(with: input) { body["input"] = v }
    if let e = bodyExtra, let o = try? JSONSerialization.jsonObject(with: e) as? [String: Any] { for (k, v) in o { body[k] = v } }
    var r = URLRequest(url: URL(string: "\(apiBase)/responses")!)
    r.httpMethod = "POST"
    r.timeoutInterval = 120
    r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    r.setValue("application/json", forHTTPHeaderField: "Content-Type")
    r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    r.httpBody = try? JSONSerialization.data(withJSONObject: body)
    var res = StreamResult()
    let t0 = Date()
    do {
        let (bytes, resp) = try await URLSession.shared.bytes(for: r)
        res.http = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if res.http != 200 {
            var buf = Data()
            for try await b in bytes { buf.append(b); if buf.count > 8000 { break } }
            res.raw = String(decoding: buf, as: UTF8.self)
            if let o = jsonObj(buf) {
                if let e = o["error"] as? [String: Any] {
                    res.errorCode = e["code"] as? String; res.errorMessage = e["message"] as? String
                    if let p = e["param"] as? String { res.errorMessage = (res.errorMessage ?? "") + " [param=\(p)]" }
                } else if let d = o["detail"] { res.errorMessage = "detail: \(d)" }
            }
            return res
        }
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]", let o = jsonObj(Data(payload.utf8)), let type = o["type"] as? String else { continue }
            if res.eventTypes.last != type { res.eventTypes.append(type) }
            switch type {
            case "response.output_text.delta":
                if let d = o["delta"] as? String { if res.ttft == nil { res.ttft = Date().timeIntervalSince(t0) }; res.text += d; if echo { print(d, terminator: ""); fflush(stdout) } }
            case "response.completed":
                res.completed = true
                if let rr = o["response"] as? [String: Any], let u = rr["usage"],
                   let d = try? JSONSerialization.data(withJSONObject: u, options: [.sortedKeys]) { res.usageJSON = String(decoding: d, as: UTF8.self) }
            case "response.output_item.done":
                if let it = o["item"] as? [String: Any], (it["type"] as? String) == "function_call" {
                    res.toolCalls.append("\(it["namespace"] as? String ?? "-")/\(it["name"] as? String ?? "?") args=\(String((it["arguments"] as? String ?? "").prefix(80)))")
                }
            case "response.incomplete": res.incomplete = true
            case "response.failed":
                res.failed = true
                if let rr = o["response"] as? [String: Any], let e = rr["error"] as? [String: Any] {
                    res.errorCode = e["code"] as? String; res.errorMessage = e["message"] as? String
                }
            case "error":
                res.failed = true
                res.errorCode = o["code"] as? String; res.errorMessage = o["message"] as? String
            default: break
            }
        }
    } catch { res.errorMessage = "transport: \(error)" }
    return res
}

func cmdAsk(args: [String]) async {
    var model: String?; var prompt: String?
    var i = 0
    while i < args.count {
        if args[i] == "--model", i + 1 < args.count { model = args[i + 1]; i += 2 } else { prompt = args[i]; i += 1 }
    }
    let t = await accessToken()
    if model == nil {
        let (_, ms, _) = await fetchModels(t)
        model = pickCheapest(ms)?.slug
    }
    guard let model else { fail("no model available; pass --model") }
    out("model: \(model)")
    var input: Data?
    if let prompt { input = try? JSONSerialization.data(withJSONObject: [["role": "user", "content": prompt]]) }
    let r = await streamResponse(model: model, token: t, bodyExtra: nil, echo: true, input: input)
    print()
    if r.http != 200 { fail("ask HTTP \(r.http) \(r.errorCode ?? "-") \(r.errorMessage ?? "") raw=\(String(r.raw.prefix(300)))") }
    if r.completed { out("completed") } else {
        fail("NOT completed failed=\(r.failed) incomplete=\(r.incomplete) code=\(r.errorCode ?? "-") msg=\(r.errorMessage ?? "-")")
    }
    out("usage: \(r.usageJSON ?? "absent")")
    out(String(format: "timing: ttft=%.2fs total=%.2fs", r.ttft ?? -1, r.total))
}

// MARK: - Probe

func json(_ s: String) -> Data { Data(s.utf8) }

func cmdProbe(args: [String]) async {
    var model: String?
    if let i = args.firstIndex(of: "--model"), i + 1 < args.count { model = args[i + 1] }
    let t = await accessToken()
    if model == nil {
        let (st, ms, err) = await fetchModels(t)
        guard st == 200, let p = pickCheapest(ms) else { fail("models HTTP \(st) \(err)") }
        model = p.slug
    }
    let m = model!
    out("probe model: \(m)")
    let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    let fnParams = #"{"type":"object","properties":{"city":{"type":"string"}},"required":["city"],"additionalProperties":false}"#
    let variants: [(String, Data?, Data?)] = [
        ("baseline", nil, nil),
        ("text.format json_schema strict", json(#"{"text":{"format":{"type":"json_schema","name":"greeting","strict":true,"schema":{"type":"object","properties":{"greeting":{"type":"string"}},"required":["greeting"],"additionalProperties":false}}}}"#), nil),
        ("reasoning effort=low", json(#"{"reasoning":{"effort":"low"}}"#), nil),
        ("reasoning effort=minimal", json(#"{"reasoning":{"effort":"minimal"}}"#), nil),
        ("function tool in namespace", json(#"{"tools":[{"type":"namespace","name":"remora","description":"Remora tools","tools":[{"type":"function","name":"get_weather","description":"Get weather for a city","parameters":\#(fnParams),"strict":true}]}],"tool_choice":"auto"}"#), nil),
        ("plain function tool", json(#"{"tools":[{"type":"function","name":"get_weather","description":"Get weather for a city","parameters":\#(fnParams),"strict":true}],"tool_choice":"auto"}"#), nil),
        ("FORCED namespaced tool call", json(#"{"tools":[{"type":"namespace","name":"remora","description":"Remora tools","tools":[{"type":"function","name":"get_weather","description":"Get weather for a city","parameters":\#(fnParams),"strict":true}]}],"tool_choice":"required"}"#), json(#"[{"role":"user","content":"What's the weather in Paris? Use the tool."}]"#)),
        ("FORCED namespaced tool call (tool_choice auto)", json(#"{"tools":[{"type":"namespace","name":"remora","description":"Remora tools","tools":[{"type":"function","name":"get_weather","description":"Get weather for a city","parameters":\#(fnParams),"strict":true}]}]}"#), json(#"[{"role":"user","content":"What's the weather in Paris? Use the tool."}]"#)),
        ("FORCED plain tool call", json(#"{"tools":[{"type":"function","name":"get_weather","description":"Get weather for a city","parameters":\#(fnParams),"strict":true}],"tool_choice":"required"}"#), json(#"[{"role":"user","content":"What's the weather in Paris? Use the tool."}]"#)),
        ("FORCED plain tool call (tool_choice auto)", json(#"{"tools":[{"type":"function","name":"get_weather","description":"Get weather for a city","parameters":\#(fnParams),"strict":true}]}"#), json(#"[{"role":"user","content":"What's the weather in Paris? Use the tool."}]"#)),
        ("image input (input_image data URL)", nil, json(#"[{"role":"user","content":[{"type":"input_text","text":"What color is this image? One word."},{"type":"input_image","image_url":"data:image/png;base64,\#(png)"}]}]"#)),
    ]
    for (name, extra, input) in variants {
        let r = await streamResponse(model: m, token: t, bodyExtra: extra, echo: false, input: input)
        let ok = r.http == 200 && r.completed
        var line = "\(name): \(ok ? "ACCEPTED" : "REJECTED") \(r.http) \(r.errorCode ?? "-") \(String((r.errorMessage ?? (ok ? "" : r.raw)).prefix(200)))"
        if r.http == 200 && !ok { line += " (stream ended: failed=\(r.failed) incomplete=\(r.incomplete))" }
        out(line)
        if ok {
            out("    events: \(r.eventTypes.joined(separator: " > "))")
            out("    text: \(String(r.text.prefix(120)))")
            out("    function_call items: \(r.toolCalls.isEmpty ? "NONE" : r.toolCalls.joined(separator: "; "))")
            out("    usage on response.completed: \(r.usageJSON ?? "ABSENT")")
        }
    }
}

func cmdMatrix() async {
    let t = await accessToken()
    let (_, ms, _) = await fetchModels(t)
    for m in listed(ms) {
        for (label, extra) in [("no-reasoning", nil), ("reasoning=low", json(#"{"reasoning":{"effort":"low"}}"#)),
                               ("reasoning=minimal", json(#"{"reasoning":{"effort":"minimal"}}"#))] as [(String, Data?)] {
            let r = await streamResponse(model: m.slug, token: t, bodyExtra: extra, echo: false)
            let ok = r.http == 200 && r.completed
            out(String(format: "%@ | %@ | %@ %d %@ %@ | ttft=%.2f total=%.2f", m.slug, label, ok ? "ACCEPTED" : "REJECTED", r.http,
                       r.errorCode ?? "-", r.errorMessage ?? "", r.ttft ?? -1, r.total))
        }
    }
}

// MARK: - Dispatch

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else {
    fail("usage: siwc-spike authorize-url | login | models | ask [--model M] \"text\" | probe [--model M] | refresh")
}
let rest = Array(args.dropFirst())
switch cmd {
case "authorize-url": cmdAuthorizeURL()
case "login": await cmdLogin()
case "models": await cmdModels()
case "ask": await cmdAsk(args: rest)
case "probe": await cmdProbe(args: rest)
case "refresh": await cmdRefresh()
case "matrix": await cmdMatrix()
default: fail("unknown subcommand \(cmd)")
}
