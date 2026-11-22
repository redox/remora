import Foundation
import LLMTestSupport
import Testing
@testable import LLM

private func makeClient(_ fake: FakeHTTPTransport, account: SIWCAccount? = nil) -> SIWCClient {
    let account = account ?? Fx.account(tokens: Fx.tokens(expiresAt: Fx.t0.addingTimeInterval(3000)))
    let tokens = TokenManager(store: InMemoryCredentialStore(account), http: fake, validator: Fx.validator(), now: { Fx.t0 })
    return SIWCClient(tokens: tokens, responses: ResponsesClient(http: fake))
}

private let refreshed = Fx.tokenResponse(access: "at-2", refresh: "rt-2", id: Fx.idToken())

@Test func siwcClientStreamsWithTheStoredToken() async throws {
    let fake = FakeHTTPTransport()
    fake.enqueue(responsesPath, .text(200, sseStream(sseDelta("Bon"), sseCompleted)))
    let c = makeClient(fake)
    #expect(c.backend == .siwc)
    let r = await collect(c.stream(sampleRequest()))
    #expect(r.events == [.textDelta("Bon"), .completed(fixtureUsage)] && r.error == nil)
    #expect(fake.requests(to: responsesPath).map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer at-1"])
    #expect(fake.requests(to: Fx.tokenPath).isEmpty)
}

@Test func unauthorizedRetriesOnceAfterForcedRefresh() async throws {
    let fake = FakeHTTPTransport()
    fake.enqueue(responsesPath, .json(401, ["detail": "Unauthorized"]))
    fake.enqueue(responsesPath, .text(200, sseStream(sseDelta("Bon"), sseCompleted)))
    fake.enqueue(Fx.tokenPath, refreshed)
    let r = await collect(makeClient(fake).stream(sampleRequest()))
    #expect(r.events == [.textDelta("Bon"), .completed(fixtureUsage)] && r.error == nil)
    #expect(fake.requests(to: Fx.tokenPath).count == 1)
    #expect(fake.requests(to: responsesPath).map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer at-1", "Bearer at-2"])
}

@Test func secondUnauthorizedSurfaces() async throws {
    let fake = FakeHTTPTransport()
    fake.enqueue(responsesPath, .json(401, ["detail": "Unauthorized"]))
    fake.enqueue(responsesPath, .json(401, ["detail": "Unauthorized"]))
    fake.enqueue(Fx.tokenPath, refreshed)
    let r = await collect(makeClient(fake).stream(sampleRequest()))
    #expect(r.events.isEmpty && r.error == .unauthorized)
    #expect(fake.requests(to: Fx.tokenPath).count == 1 && fake.requests(to: responsesPath).count == 2)
}

@Test func unauthorizedAfterEventsIsNotRetried() async throws {
    let fake = FakeHTTPTransport()
    let invalid = sseEvent("response.failed", #","response":{"error":{"code":"subscription_sharing_invalid_user"}}"#)
    fake.enqueue(responsesPath, .text(200, sseStream(sseDelta("Bon"), invalid)))
    let r = await collect(makeClient(fake).stream(sampleRequest()))
    #expect(r.events == [.textDelta("Bon")] && r.error == .unauthorized)
    #expect(fake.requests.count == 1)
}

@Test func otherErrorsAreNotRetried() async throws {
    let fake = FakeHTTPTransport()
    fake.enqueue(responsesPath, .json(429, ["error": ["code": "subscription_sharing_usage_limit_exceeded"]]))
    #expect(await collect(makeClient(fake).stream(sampleRequest())).error == .usageLimit)
    #expect(fake.requests.count == 1)
}

@Test func notSignedInSurfacesWithoutNetwork() async throws {
    let fake = FakeHTTPTransport()
    let tokens = TokenManager(store: InMemoryCredentialStore(), http: fake, validator: Fx.validator(), now: { Fx.t0 })
    let c = SIWCClient(tokens: tokens, responses: ResponsesClient(http: fake))
    #expect(await collect(c.stream(sampleRequest())).error == .notSignedIn)
    #expect(fake.requests.isEmpty)
}

@Test func failedRefreshAfter401SurfacesTheRefreshError() async throws {
    let fake = FakeHTTPTransport()
    fake.enqueue(responsesPath, .json(401, ["detail": "Unauthorized"]))
    fake.enqueue(Fx.tokenPath, .json(400, ["error": "invalid_grant"]))
    #expect(await collect(makeClient(fake).stream(sampleRequest())).error == .needsSignIn)
    #expect(fake.requests(to: responsesPath).count == 1)
}
