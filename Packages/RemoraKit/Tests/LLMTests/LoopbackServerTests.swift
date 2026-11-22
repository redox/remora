import Foundation
import Testing
@testable import LLM

// Every listener here binds 127.0.0.1 port 0 (ephemeral), except `busyPortFallsBack`, which asks for
// the ephemeral port another test listener already holds.

@Test func loopbackServesCallbackOnEphemeralPort() async throws {
    let s = LoopbackServer(ports: [])
    let port = try await s.start()
    defer { s.stop() }
    #expect(port != 0 && !SIWC.ports.contains(port))
    async let q = s.waitForCallback(timeout: .seconds(5))
    let stray = try await Fx.get("http://127.0.0.1:\(port)/favicon.ico")  // 404, keeps waiting
    #expect(stray.status == 404)
    // The callback's page is only served once the flow reports the result, so it runs concurrently.
    let browser = Task { try await Fx.get("http://127.0.0.1:\(port)/auth/callback?code=c&state=s") }
    #expect(try await q["code"] == "c")
    s.finish(signedIn: true)
    let page = try await browser.value
    #expect(page.status == 200 && page.body.contains("Signed in to Remora. You can close this tab."))
}

@Test func failurePageAndLaterCallbacksIgnored() async throws {
    let s = LoopbackServer(ports: [])
    let port = try await s.start()
    defer { s.stop() }
    async let q = s.waitForCallback(timeout: .seconds(5))
    let first = Task { try await Fx.get("http://127.0.0.1:\(port)/auth/callback?code=first&state=s") }
    #expect(try await q["code"] == "first")
    // The first valid callback wins: a second one is answered 404 and changes nothing.
    let second = try await Fx.get("http://127.0.0.1:\(port)/auth/callback?code=second&state=s")
    #expect(second.status == 404)
    s.finish(signedIn: false)
    let page = try await first.value
    #expect(page.status == 200 && page.body.contains("Sign-in failed. Return to Remora."))
}

@Test func malformedAndOtherMethodsKeepWaiting() async throws {
    let s = LoopbackServer(ports: [])
    let port = try await s.start()
    defer { s.stop() }
    async let q = s.waitForCallback(timeout: .seconds(5))
    var post = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/auth/callback?code=x&state=s")!)
    post.httpMethod = "POST"
    let (_, r) = try await Fx.session.data(for: post)
    #expect((r as! HTTPURLResponse).statusCode == 404)
    let browser = Task { try await Fx.get("http://127.0.0.1:\(port)/auth/callback?code=ok&state=s") }
    #expect(try await q["code"] == "ok")
    s.finish(signedIn: true)
    _ = try await browser.value
}

@Test func callbackBeforeWaitIsKept() async throws {
    let s = LoopbackServer(ports: [])
    let port = try await s.start()
    defer { s.stop() }
    let browser = Task { try await Fx.get("http://127.0.0.1:\(port)/auth/callback?code=early&state=s") }
    try await Task.sleep(for: .milliseconds(200))
    #expect(try await s.waitForCallback(timeout: .seconds(5))["code"] == "early")
    s.stop()  // without finish(): the pending browser still gets the failure page
    #expect(try await browser.value.body.contains("Sign-in failed"))
}

@Test func busyPortFallsBack() async throws {
    let first = LoopbackServer(ports: [])
    let p = try await first.start()
    defer { first.stop() }
    let second = LoopbackServer(ports: [p])
    let q = try await second.start()
    defer { second.stop() }
    #expect(q != p && q != 0)
}

@Test func waitTimesOut() async throws {
    let s = LoopbackServer(ports: [])
    _ = try await s.start()
    defer { s.stop() }
    await #expect(throws: AuthError.timedOut) { try await s.waitForCallback(timeout: .milliseconds(100)) }
}

@Test func cancellingTheWaitEndsIt() async throws {
    let s = LoopbackServer(ports: [])
    _ = try await s.start()
    defer { s.stop() }
    let t = Task { try await s.waitForCallback(timeout: .seconds(30)) }
    try await Task.sleep(for: .milliseconds(50))
    t.cancel()
    await #expect(throws: CancellationError.self) { try await t.value }
}

@Test func stopEndsTheWait() async throws {
    let s = LoopbackServer(ports: [])
    _ = try await s.start()
    let t = Task { try await s.waitForCallback(timeout: .seconds(30)) }
    try await Task.sleep(for: .milliseconds(50))
    s.stop()
    await #expect(throws: CancellationError.self) { try await t.value }
}

@Test func aWaitRegisteredAfterTheAttemptEndedFailsAtOnce() async throws {
    let s = LoopbackServer(ports: [])
    _ = try await s.start()
    defer { s.stop() }
    s.end(with: AuthError.timedOut)  // e.g. the timer fired before the wait installed itself
    let wait = Task { try await s.waitForCallback(timeout: .seconds(30)) }
    let guardTask = Task { try await Task.sleep(for: .seconds(2)); wait.cancel() }
    defer { guardTask.cancel() }
    await #expect(throws: AuthError.timedOut) { try await wait.value }
}

@Test func nearZeroTimeoutNeverHangs() async throws {
    for _ in 0..<50 {
        let s = LoopbackServer(ports: [])
        _ = try await s.start()
        // A guard cancels a hung wait, which would surface as CancellationError instead of timedOut.
        let wait = Task { try await s.waitForCallback(timeout: .nanoseconds(1)) }
        let guardTask = Task { try await Task.sleep(for: .seconds(2)); wait.cancel() }
        await #expect(throws: AuthError.timedOut) { try await wait.value }
        guardTask.cancel()
        s.stop()
    }
}
