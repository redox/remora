import Foundation
import LLMTestSupport
import Storage
import Synchronization
import Testing
@testable import LLM

private let modelsPath = "/v1/models"

private func spikeBody() -> [String: Any] {
    var models: [[String: Any]] = spikeSlugs.map { ["slug": $0, "display_name": $0.uppercased(), "visibility": "list"] }
    models.insert(["slug": "gpt-reserve", "display_name": "r", "visibility": "hide"], at: 3)
    models.append(["slug": "codex-auto-review", "display_name": "c", "visibility": "hide"])
    return ["models": models]
}

private final class Clock: @unchecked Sendable {
    private let t = Mutex(Fx.t0)
    var now: Date { t.withLock { $0 } }
    func advance(_ s: TimeInterval) { t.withLock { $0 = $0.addingTimeInterval(s) } }
}

private func makeCatalog(_ fake: FakeHTTPTransport, settings: SettingsStore? = nil, clock: Clock = Clock()) throws -> (ModelCatalog, SettingsStore) {
    let settings = try settings ?? SettingsStore(AppDatabase.inMemory())
    let account = Fx.account(tokens: Fx.tokens(expiresAt: Fx.t0.addingTimeInterval(1_000_000)))
    let tokens = TokenManager(store: InMemoryCredentialStore(account), http: fake, validator: Fx.validator(), now: { clock.now })
    return (ModelCatalog(http: fake, tokens: tokens, settings: settings, now: { clock.now }), settings)
}

@Test func parsesCatalogKeepingServerOrderAndListVisibility() async throws {
    let fake = FakeHTTPTransport()
    fake.enqueue(modelsPath, .json(200, spikeBody()))
    let (catalog, _) = try makeCatalog(fake)
    let models = try await catalog.refresh()
    #expect(models.map(\.slug) == spikeSlugs)
    #expect(models.first?.displayName == "GPT-6.2-SOL")
    let req = try #require(fake.requests(to: modelsPath).first)
    #expect(req.httpMethod == "GET" && req.value(forHTTPHeaderField: "Authorization") == "Bearer at-1")
    #expect(req.url?.absoluteString == "https://api.openai.com/v1/models")
}

@Test func toleratesTheDataIdShape() async throws {
    let fake = FakeHTTPTransport()
    fake.enqueue(modelsPath, .json(200, ["data": [["id": "gpt-6-luna"], ["id": "gpt-6.1-terra"], ["id": "gpt-6-luna"]]]))
    let (catalog, _) = try makeCatalog(fake)
    #expect(try await catalog.refresh().map(\.slug) == ["gpt-6-luna", "gpt-6.1-terra"])
}

@Test func persistsAndRestoresTheCatalog() async throws {
    let fake = FakeHTTPTransport()
    fake.enqueue(modelsPath, .json(200, spikeBody()))
    let (catalog, settings) = try makeCatalog(fake)
    let empty = await catalog.cached()
    #expect(empty.models.isEmpty && empty.fetchedAt == nil)
    _ = try await catalog.refresh()
    #expect(await catalog.cached().fetchedAt == Fx.t0)
    // A fresh actor over the same settings sees the stored list without any network.
    let (again, _) = try makeCatalog(FakeHTTPTransport(), settings: settings)
    let c = await again.cached()
    #expect(c.models.map(\.slug) == spikeSlugs && c.fetchedAt == Fx.t0)
}

@Test func refreshIfStaleOnlyFetchesWhenOld() async throws {
    let fake = FakeHTTPTransport()
    fake.handle(modelsPath) { _ in .json(200, spikeBody()) }
    let clock = Clock()
    let (catalog, _) = try makeCatalog(fake, clock: clock)
    await catalog.refreshIfStale()  // nothing cached: fetches
    #expect(fake.requests(to: modelsPath).count == 1)
    clock.advance(3600)
    await catalog.refreshIfStale()  // fresh: no fetch
    #expect(fake.requests(to: modelsPath).count == 1)
    clock.advance(86_400)
    await catalog.refreshIfStale()  // stale again
    #expect(fake.requests(to: modelsPath).count == 2)
}

@Test func failedRefreshKeepsTheCachedList() async throws {
    let fake = FakeHTTPTransport()
    fake.enqueue(modelsPath, .json(200, spikeBody()))
    let (catalog, _) = try makeCatalog(fake)
    _ = try await catalog.refresh()
    fake.enqueue(modelsPath, .json(503, ["detail": "x"]))
    await #expect(throws: LLMError.temporarilyUnavailable(code: nil)) { try await catalog.refresh() }
    #expect(await catalog.cached().models.map(\.slug) == spikeSlugs)
    fake.enqueue(modelsPath, .json(200, ["models": [] as [Any]]))
    await #expect(throws: LLMError.self) { try await catalog.refresh() }  // an empty list is not a catalog
    #expect(await catalog.cached().models.count == spikeSlugs.count)
}

@Test func refreshIfStaleAbsorbsErrors() async throws {
    let fake = FakeHTTPTransport()
    fake.enqueue(modelsPath, error: URLError(.notConnectedToInternet))
    let (catalog, _) = try makeCatalog(fake)
    await catalog.refreshIfStale()
    #expect(await catalog.cached().models.isEmpty)
}

@Test func modelsRequestRetriesOnceAfter401() async throws {
    let fake = FakeHTTPTransport()
    fake.enqueue(modelsPath, .json(401, ["detail": "Unauthorized"]))
    fake.enqueue(modelsPath, .json(200, spikeBody()))
    fake.enqueue(Fx.tokenPath, Fx.tokenResponse(access: "at-2", refresh: "rt-2", id: Fx.idToken()))
    let (catalog, _) = try makeCatalog(fake)
    #expect(try await catalog.refresh().count == spikeSlugs.count)
    #expect(fake.requests(to: modelsPath).map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer at-1", "Bearer at-2"])
}

@Test func malformedModelEntriesAreSkippedAndValidOnesKept() {
    let body: [String: Any] = ["models": [
        ["slug": "gpt-6-luna", "display_name": "L", "visibility": "list"],
        "garbage", 7, NSNull(),
        ["slug": 5, "visibility": "list"],
        ["slug": "gpt-6.1-terra", "display_name": "T", "visibility": "list"],
    ] as [Any]]
    let data = try! JSONSerialization.data(withJSONObject: body)
    #expect(ModelCatalog.parse(data)?.map(\.slug) == ["gpt-6-luna", "gpt-6.1-terra"])
}

@Test func negativeCacheAgeCountsAsStale() async throws {
    let fake = FakeHTTPTransport()
    fake.handle(modelsPath) { _ in .json(200, spikeBody()) }
    let clock = Clock()
    let (catalog, _) = try makeCatalog(fake, clock: clock)
    await catalog.refreshIfStale()
    clock.advance(-7200)  // the clock moved back
    await catalog.refreshIfStale()
    #expect(fake.requests(to: modelsPath).count == 2)
}
