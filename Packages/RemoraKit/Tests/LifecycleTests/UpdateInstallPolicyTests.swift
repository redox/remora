import Testing
@testable import Lifecycle

@Test func neverInstallsWhileBusy() {
    #expect(!UpdateInstallPolicy.shouldInstallNow(busy: true, idleSeconds: 10_000, readyFor: 200_000))
}

@Test func installsWhenIdleLongEnough() {
    #expect(UpdateInstallPolicy.shouldInstallNow(busy: false, idleSeconds: 120, readyFor: 0))
    #expect(!UpdateInstallPolicy.shouldInstallNow(busy: false, idleSeconds: 119, readyFor: 0))
}

@Test func forcesAfterADayWhenNotBusy() {
    #expect(UpdateInstallPolicy.shouldInstallNow(busy: false, idleSeconds: 0, readyFor: 86_400))
    #expect(!UpdateInstallPolicy.shouldInstallNow(busy: false, idleSeconds: 0, readyFor: 86_399))
}
