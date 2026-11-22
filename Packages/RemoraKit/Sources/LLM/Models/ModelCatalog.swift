import Foundation
import Storage
import os

/// The models the signed-in account may use (`GET /v1/models`), cached in the `llm.catalog` setting.
public actor ModelCatalog {
    static let settingKey = "llm.catalog"
    private struct Stored: Codable {
        var models: [ModelInfo]
        var fetchedAt: Date
    }

    private let http: any HTTPTransport
    private let tokens: TokenManager
    private let settings: SettingsStore
    private let now: @Sendable () -> Date
    private let baseURL: URL
    private var stored: Stored?
    private var loaded = false

    private static let log = Logger(subsystem: "dev.remora", category: "models")

    public init(http: any HTTPTransport, tokens: TokenManager, settings: SettingsStore,
                baseURL: URL = URL(string: SIWC.apiBase)!, now: @escaping @Sendable () -> Date = Date.init) {
        self.http = http
        self.tokens = tokens
        self.settings = settings
        self.baseURL = baseURL
        self.now = now
    }

    /// What the last successful fetch returned (server order); empty before the first one.
    public func cached() -> (models: [ModelInfo], fetchedAt: Date?) {
        load()
        return (stored?.models ?? [], stored?.fetchedAt)
    }

    /// Fetches and stores the list. On failure the cached list stays. Throws `LLMError`.
    @discardableResult
    public func refresh() async throws -> [ModelInfo] {
        do {
            var token = try await tokens.accessToken()
            var (status, body) = try await fetch(token)
            if status == 401 {
                token = try await tokens.forceRefresh(rejected: token)
                (status, body) = try await fetch(token)
            }
            guard status == 200 else {
                let e = ErrorClassifier.classify(status: status, body: body)
                Self.log.error("models: HTTP \(status, privacy: .public)")
                throw e
            }
            guard let models = Self.parse(body), !models.isEmpty else {
                Self.log.error("models: unusable response")
                throw LLMError.badRequest(code: "unusable_model_list", param: nil)
            }
            let record = Stored(models: models, fetchedAt: now())
            stored = record
            loaded = true
            do { try settings.setValue(record, forKey: Self.settingKey) } catch { Self.log.error("models: could not persist the list") }
            return models
        } catch {
            throw LLMError.wrapping(error)
        }
    }

    /// Refreshes when nothing is cached or the cache is older than `maxAge`. Errors are absorbed.
    public func refreshIfStale(maxAge: TimeInterval = 86_400) async {
        load()
        // A negative age (clock moved back) counts as stale.
        if let at = stored?.fetchedAt {
            let age = now().timeIntervalSince(at)
            if age >= 0, age < maxAge { return }
        }
        _ = try? await refresh()
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        stored = try? settings.value(Stored.self, forKey: Self.settingKey)
    }

    private func fetch(_ token: String) async throws -> (Int, Data) {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await http.data(for: request)
        return (response.statusCode, data)
    }

    /// `{"models":[{slug, display_name, visibility}]}` (only `visibility == "list"`), or the plain
    /// `{"data":[{"id"}]}` shape (all of them). Duplicates keep their first position.
    static func parse(_ body: Data) -> [ModelInfo]? {
        guard let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
        var out: [ModelInfo] = []
        var seen = Set<String>()
        func add(_ slug: String?, _ name: String?) {
            guard let slug, !slug.isEmpty, seen.insert(slug).inserted else { return }
            out.append(ModelInfo(slug: slug, displayName: name ?? slug))
        }
        // Malformed entries are skipped; the valid ones stay.
        if let models = o["models"] as? [Any] {
            for case let m as [String: Any] in models where (m["visibility"] as? String) == "list" {
                add(m["slug"] as? String, m["display_name"] as? String)
            }
            return out
        }
        if let data = o["data"] as? [Any] {
            for case let m as [String: Any] in data { add(m["id"] as? String, m["display_name"] as? String) }
            return out
        }
        return nil
    }
}
