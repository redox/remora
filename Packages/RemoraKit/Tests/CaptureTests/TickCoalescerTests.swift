import Testing
@testable import Capture

@Test func coalescesWhileATickIsRunning() {
    var c = TickCoalescer()
    let first = c.begin()
    let second = c.begin()         // still running: skipped
    _ = c.finish(.unchanged)
    let third = c.begin()
    #expect(first && !second && third)
}

@Test func reportsTimeoutStreakOncePerStreak() {
    var c = TickCoalescer(timeoutStreakThreshold: 5)
    var events: [TickCoalescer.Event] = []
    for _ in 0..<8 {
        let began = c.begin()
        #expect(began)
        if let e = c.finish(.timedOut) { events.append(e) }
    }
    #expect(events == [.timeoutStreak(5)])
}

@Test func streakResetsOnAnyOtherOutcome() {
    var c = TickCoalescer(timeoutStreakThreshold: 5)
    var events: [TickCoalescer.Event] = []
    let outcomes: [CaptureOutcome] = Array(repeating: .timedOut, count: 4) + [.stored(1)]
        + Array(repeating: .timedOut, count: 5)
    for o in outcomes {
        _ = c.begin()
        if let e = c.finish(o) { events.append(e) }
    }
    #expect(events == [.timeoutStreak(5)])
}

@Test func newStreakAfterRecoveryIsReportedAgain() {
    var c = TickCoalescer(timeoutStreakThreshold: 2)
    var events: [TickCoalescer.Event] = []
    for o: CaptureOutcome in [.timedOut, .timedOut, .timedOut, .noWindow, .timedOut, .timedOut] {
        _ = c.begin()
        if let e = c.finish(o) { events.append(e) }
    }
    #expect(events == [.timeoutStreak(2), .timeoutStreak(2)])
}

@Test func failedOutcomeIsReported() {
    var c = TickCoalescer()
    _ = c.begin()
    let failed = c.finish(.failed)
    _ = c.begin()
    let paused = c.finish(.paused)
    #expect(failed == .failed && paused == nil)
}
