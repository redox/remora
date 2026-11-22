import Foundation
import Testing
@testable import Capture

private let t0 = ContinuousClock.now
private func at(_ seconds: Double) -> ContinuousClock.Instant { t0.advanced(by: .seconds(seconds)) }
private func id(pid: Int32 = 42, window: Int? = 7, title: String? = "Doc",
                url: URL? = nil, priv: Bool = false) -> ContextIdentity {
    ContextIdentity(pid: pid, window: window, windowTitle: title, url: url, isPrivateBrowsing: priv)
}

/// Polls at t0 (sample arrives at t0+0.01) and at t0+1 (sample at t0+1.01) with the given
/// identities and context events in between; returns the second verdict.
private func verdict(_ first: ContextIdentity?, _ second: ContextIdentity?,
                     events: [(ContextEvent, Double)] = []) -> Bool {
    var a = ClipboardAttribution(pollInterval: .seconds(1))
    _ = a.completePoll(identity: first, pasteboardReadAt: at(0), now: at(0.01))
    for (event, time) in events { a.record(event, at: at(time)) }
    return a.completePoll(identity: second, pasteboardReadAt: at(1), now: at(1.01))
}

@Test func sameContextAcrossPollsIsAttributable() {
    #expect(verdict(id(), id()))
}

@Test func firstPollIsNeverAttributable() {
    var a = ClipboardAttribution(pollInterval: .seconds(1))
    let attributable = a.completePoll(identity: id(), pasteboardReadAt: at(0), now: at(0))
    #expect(!attributable)
}

@Test func frontmostAppChangedDrops() {
    #expect(!verdict(id(pid: 42), id(pid: 99)))
}

@Test func windowChangedDrops() {
    #expect(!verdict(id(window: 7), id(window: 8)))
}

@Test func windowTitleChangedDrops() {
    #expect(!verdict(id(title: "Bank — Statement"), id(title: "Notes")))
}

@Test func urlChangedDrops() {
    #expect(!verdict(id(url: URL(string: "https://bank.example/a")),
                     id(url: URL(string: "https://news.example/b"))))
}

@Test func privateFlagChangedDrops() {
    #expect(!verdict(id(priv: true), id(priv: false)))
}

@Test func unknownContextDrops() {
    #expect(!verdict(id(), nil))
    #expect(!verdict(nil, id()))
}

@Test func activationSincePreviousPollDrops() {
    // Cmd-Tab away and back between polls: same identity at both ends, but an activation.
    #expect(!verdict(id(), id(), events: [(.appActivated, 0.5)]))
}

@Test func activationWithinLastIntervalDrops() {
    // Polls closer than the interval (timer drift): an activation just before the previous
    // read is still within one interval of detection, so the context may not have settled.
    var a = ClipboardAttribution(pollInterval: .seconds(1))
    _ = a.completePoll(identity: id(), pasteboardReadAt: at(0), now: at(0))
    a.record(.appActivated, at: at(-0.3))
    let attributable = a.completePoll(identity: id(), pasteboardReadAt: at(0.5), now: at(0.5))
    #expect(!attributable)
}

@Test func oldActivationDoesNotDrop() {
    #expect(verdict(id(), id(), events: [(.appActivated, -30)]))
}

@Test func titleChangeBetweenPollsDrops() {
    // Copy in an Incognito tab, Ctrl+Tab before the previous poll's delayed sample: both
    // samples show the new tab, only the title-change event reveals the switch.
    #expect(!verdict(id(title: "B"), id(title: "B"), events: [(.titleChanged, 0.02)]))
}

@Test func windowFocusRoundTripDrops() {
    // Same app, A → B → A between polls: identical samples, two focus events.
    #expect(!verdict(id(), id(), events: [(.focusedWindowChanged, 0.3), (.focusedWindowChanged, 0.6)]))
}

@Test func valueChangesAloneStillStore() {
    // Typing fires AXValueChanged constantly; it is not a context switch.
    #expect(verdict(id(), id(), events: [(.valueChanged, 0.2), (.valueChanged, 0.9)]))
}

@Test func contextEventsFromAXNotificationNames() {
    #expect(ContextEvent(axNotification: "AXFocusedWindowChanged") == .focusedWindowChanged)
    #expect(ContextEvent(axNotification: "AXTitleChanged") == .titleChanged)
    #expect(ContextEvent(axNotification: "AXValueChanged") == .valueChanged)
    #expect(ContextEvent(axNotification: "AXSomethingElse") == nil)
    #expect(ContextEvent(axNotification: "AXWindowMoved") == nil)
    #expect(ContextEvent(axNotification: "AXWindowResized") == nil)
}

@Test func observerAttachedAfterPreviousReadDrops() {
    // Switches made before the AX observer attached were unseen: any copy whose interval
    // started before attachment is dropped.
    #expect(!verdict(id(), id(), events: [(.observerAttached, 0.4)]))
}

@Test func observerAttachedLongAgoDoesNotDrop() {
    #expect(verdict(id(), id(), events: [(.observerAttached, -30)]))
}
