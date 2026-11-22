import Testing
@testable import ChatBar

@Test func hoverOpensAfterDelayAndClosesOnExit() {
    var i = BarInteraction(pinned: false)
    #expect(i.handle(.mouseEntered, openOnHover: true) == [.startHoverTimer(0.15)])
    #expect(i.handle(.hoverTimerFired, openOnHover: true) == [.expand])
    #expect(i.state == .peeking)
    #expect(i.handle(.mouseExited, openOnHover: true) == [.startExitTimer(0.6)])
    #expect(i.handle(.exitTimerFired, openOnHover: true) == [.collapse, .cancelTimers])
    #expect(i.state == .collapsed)
}
@Test func reenteringWhilePeekingCancelsExitTimer() {
    var i = BarInteraction(pinned: false)
    _ = i.handle(.mouseEntered, openOnHover: true); _ = i.handle(.hoverTimerFired, openOnHover: true)
    _ = i.handle(.mouseExited, openOnHover: true)
    #expect(i.handle(.mouseEntered, openOnHover: true) == [.cancelTimers])
    #expect(i.handle(.exitTimerFired, openOnHover: true) == [])
    #expect(i.state == .peeking)
}
@Test func hoverOffNeedsClick() {
    var i = BarInteraction(pinned: false)
    #expect(i.handle(.mouseEntered, openOnHover: false) == [])
    #expect(i.handle(.clickBar, openOnHover: false) == [.cancelTimers, .expand, .focusInput])
    #expect(i.state == .open)
}
@Test func clickedPanelIgnoresMouseExit() {
    var i = BarInteraction(pinned: false)
    _ = i.handle(.mouseEntered, openOnHover: true); _ = i.handle(.hoverTimerFired, openOnHover: true)
    _ = i.handle(.becameKey, openOnHover: true)
    #expect(i.state == .open)
    #expect(i.handle(.mouseExited, openOnHover: true) == [])
    #expect(i.handle(.resignedKey, openOnHover: true) == [.collapse, .cancelTimers])
    #expect(i.state == .collapsed)
}
@Test func pinnedNeverAutoCollapses() {
    var i = BarInteraction(pinned: false)
    _ = i.handle(.setPinned(true), openOnHover: true)
    #expect(i.state == .open && i.pinned)
    #expect(i.handle(.resignedKey, openOnHover: true) == [])
    #expect(i.handle(.exitTimerFired, openOnHover: true) == [])
    #expect(i.handle(.escape, openOnHover: true) == [])
    #expect(i.state == .open)
}
@Test func toggleCollapsesAndOpens() {
    var i = BarInteraction(pinned: false)
    #expect(i.handle(.toggle, openOnHover: true) == [.cancelTimers, .expand, .focusInput])
    #expect(i.handle(.toggle, openOnHover: true) == [.collapse, .cancelTimers])
    #expect(i.state == .collapsed)
}
@Test func escapeStopsStreamFirst() {
    var i = BarInteraction(pinned: false)
    _ = i.handle(.openRequested, openOnHover: true)
    _ = i.handle(.streaming(true), openOnHover: true)
    #expect(i.handle(.escape, openOnHover: true) == [.stopStream])
    #expect(i.state == .open)
    _ = i.handle(.streaming(false), openOnHover: true)
    #expect(i.handle(.escape, openOnHover: true) == [.collapse, .cancelTimers])
}

@Test func pinnedInitStartsOpenAndSurvivesResign() {
    var i = BarInteraction(pinned: true)
    #expect(i.state == .open)
    #expect(i.handle(.resignedKey, openOnHover: true) == [])
    #expect(i.handle(.setPinned(true), openOnHover: true) == [])
}
@Test func toggleWhilePinnedStillCollapses() {
    var i = BarInteraction(pinned: true)
    #expect(i.handle(.toggle, openOnHover: true) == [.collapse, .cancelTimers])
    #expect(i.state == .collapsed)
}
@Test func setPinnedFromPeekingOpensAndCancelsTimers() {
    var i = BarInteraction(pinned: false)
    _ = i.handle(.mouseEntered, openOnHover: true); _ = i.handle(.hoverTimerFired, openOnHover: true)
    _ = i.handle(.mouseExited, openOnHover: true)
    #expect(i.handle(.setPinned(true), openOnHover: true) == [.cancelTimers])
    #expect(i.state == .open)
    #expect(i.handle(.exitTimerFired, openOnHover: true) == [])
    #expect(i.state == .open)
}
@Test func escapeWhilePeekingCollapses() {
    var i = BarInteraction(pinned: false)
    _ = i.handle(.mouseEntered, openOnHover: true); _ = i.handle(.hoverTimerFired, openOnHover: true)
    #expect(i.handle(.escape, openOnHover: true) == [.collapse, .cancelTimers])
    #expect(i.state == .collapsed)
}
@Test func staleHoverTimerAfterMouseExitedDoesNothing() {
    var i = BarInteraction(pinned: false)
    _ = i.handle(.mouseEntered, openOnHover: true)
    #expect(i.handle(.mouseExited, openOnHover: true) == [.cancelTimers])
    #expect(i.handle(.hoverTimerFired, openOnHover: true) == [])
    #expect(i.state == .collapsed)
}
@Test func staleHoverTimerAfterClickDoesNothing() {
    var i = BarInteraction(pinned: false)
    _ = i.handle(.mouseEntered, openOnHover: true)
    _ = i.handle(.clickBar, openOnHover: true)
    #expect(i.handle(.hoverTimerFired, openOnHover: true) == [])
    #expect(i.state == .open)
}
