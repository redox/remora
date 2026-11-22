import Foundation
import Testing
@testable import Input

@Test func singleTapIsReportedAfterDoubleTapWindow() {
    var d = TapDetector(doubleTap: true, hold: true)
    #expect(d.handle(.triggerDown, at: 0) == nil)
    #expect(d.handle(.triggerUp, at: 0.12) == nil)
    #expect(abs(d.nextDeadline! - 0.42) < 1e-9)
    #expect(d.tick(at: 0.43) == .singleTap)
    #expect(d.nextDeadline == nil)
}

@Test func tickBeforeDeadlineDoesNothing() {
    var d = TapDetector(doubleTap: true, hold: true)
    _ = d.handle(.triggerDown, at: 0)
    _ = d.handle(.triggerUp, at: 0.1)
    #expect(d.tick(at: 0.2) == nil)
    #expect(d.tick(at: 0.41) == .singleTap)
    #expect(d.tick(at: 0.9) == nil)
}

@Test func tapFiresImmediatelyWithoutDoubleTap() {
    var d = TapDetector(doubleTap: false, hold: true)
    #expect(d.handle(.triggerDown, at: 0) == nil)
    #expect(d.handle(.triggerUp, at: 0.1) == .singleTap)
    #expect(d.tick(at: 5) == nil)
}

@Test func doubleTapEmitsOnlyOneGesture() {
    var d = TapDetector(doubleTap: true, hold: true)
    var outputs: [TapDetector.Output] = []
    for (input, t) in [(TapDetector.Input.triggerDown, 0.0), (.triggerUp, 0.1), (.triggerDown, 0.3), (.triggerUp, 0.4)] {
        if let o = d.handle(input, at: t) { outputs.append(o) }
        if let o = d.tick(at: t) { outputs.append(o) }
    }
    if let o = d.tick(at: 2) { outputs.append(o) }
    #expect(outputs == [.doubleTap])
}

@Test func secondTapAfterGapIsANewTap() {
    var d = TapDetector(doubleTap: true, hold: false)
    _ = d.handle(.triggerDown, at: 0)
    _ = d.handle(.triggerUp, at: 0.1)
    // The timer was late: the next press still reports the pending rewrite first.
    #expect(d.handle(.triggerDown, at: 0.5) == .singleTap)
    #expect(d.handle(.triggerUp, at: 0.6) == nil)
    #expect(d.tick(at: 0.95) == .singleTap)
}

@Test func holdArmsAtThresholdAndCommitsOnCleanRelease() {
    var d = TapDetector(doubleTap: true, hold: true)
    #expect(d.handle(.triggerDown, at: 0) == nil)
    #expect(abs(d.nextDeadline! - 0.40) < 1e-9)
    #expect(d.tick(at: 0.39) == nil)
    #expect(d.tick(at: 0.40) == .holdArmed)
    #expect(d.nextDeadline == nil)
    #expect(d.tick(at: 0.9) == nil)
    #expect(d.handle(.triggerUp, at: 1.0) == .holdReleased)
    #expect(d.tick(at: 2.0) == nil)
}

@Test(arguments: [TapDetector.Input.otherKey, .mouse, .otherModifier])
func armedHoldIsCancelledByOtherInput(_ input: TapDetector.Input) {
    var d = TapDetector(doubleTap: true, hold: true)
    _ = d.handle(.triggerDown, at: 0)
    #expect(d.tick(at: 0.4) == .holdArmed)
    #expect(d.handle(input, at: 0.6) == .holdCancelled)
    #expect(d.handle(input, at: 0.7) == nil)
    #expect(d.handle(.triggerUp, at: 1.0) == nil)
    #expect(d.tick(at: 2) == nil)
}

@Test func lateHoldTickStillCommitsOnCleanRelease() {
    var d = TapDetector(doubleTap: true, hold: true)
    _ = d.handle(.triggerDown, at: 0)
    #expect(d.handle(.triggerUp, at: 0.8) == .holdReleased)
}

@Test func secondPressHeldArmsTheHold() {
    var d = TapDetector(doubleTap: true, hold: true)
    _ = d.handle(.triggerDown, at: 0)
    _ = d.handle(.triggerUp, at: 0.1)
    _ = d.handle(.triggerDown, at: 0.2)
    #expect(d.tick(at: 0.61) == .holdArmed)
    #expect(d.handle(.triggerUp, at: 0.9) == .holdReleased)
}

@Test func gestureStartSpansTheWholeGesture() {
    var d = TapDetector(doubleTap: true, hold: true)
    #expect(d.gestureStart == nil)
    _ = d.handle(.triggerDown, at: 1)
    _ = d.handle(.triggerUp, at: 1.1)
    #expect(d.gestureStart == 1)
    _ = d.handle(.triggerDown, at: 1.3)
    #expect(d.gestureStart == 1)
    _ = d.handle(.triggerUp, at: 1.4)
    #expect(d.gestureStart == nil)
    _ = d.handle(.triggerDown, at: 5)
    _ = d.tick(at: 5.4)
    #expect(d.gestureStart == 5)
    d.reset()
    #expect(d.gestureStart == nil && d.handle(.triggerUp, at: 6) == nil)
}

@Test func gestureGuardRejectsUnseenInputDuringGesture() {
    // A hot key consumed by another app 0.1 s into a 0.3 s gesture.
    #expect(GestureGuard.interrupted(lastKeyDownAge: 0.2, lastMouseDownAge: 50, gestureDuration: 0.3))
    #expect(GestureGuard.interrupted(lastKeyDownAge: 50, lastMouseDownAge: 0.05, gestureDuration: 0.3))
    // Typing that ended before the trigger went down.
    #expect(!GestureGuard.interrupted(lastKeyDownAge: 0.35, lastMouseDownAge: 9, gestureDuration: 0.3))
}

@Test(arguments: [[TapDetector.Input.otherKey], [.mouse], [.otherModifier], [.otherModifier, .otherKey]])
func modifierUseNeverFires(_ between: [TapDetector.Input]) {
    for doubleTap in [true, false] {
        var d = TapDetector(doubleTap: doubleTap, hold: true)
        var outputs: [TapDetector.Output] = []
        if let o = d.handle(.triggerDown, at: 0) { outputs.append(o) }
        for (i, input) in between.enumerated() {
            if let o = d.handle(input, at: 0.05 + Double(i) * 0.01) { outputs.append(o) }
        }
        if let o = d.handle(.triggerUp, at: 0.2) { outputs.append(o) }
        if let o = d.tick(at: 1.2) { outputs.append(o) }
        #expect(outputs.isEmpty)
        #expect(d.nextDeadline == nil)
    }
    // Hold path: a key pressed while the trigger is held kills the hold.
    var h = TapDetector(doubleTap: true, hold: true)
    _ = h.handle(.triggerDown, at: 0)
    _ = h.handle(between[0], at: 0.1)
    #expect(h.tick(at: 0.5) == nil)
    #expect(h.handle(.triggerUp, at: 0.9) == nil)
    // A fresh clean press works again afterwards.
    _ = h.handle(.triggerDown, at: 2)
    #expect(h.handle(.triggerUp, at: 2.1) == nil)
    #expect(h.tick(at: 2.5) == .singleTap)
}

@Test func dirtySecondPressCancelsPendingRewrite() {
    var d = TapDetector(doubleTap: true, hold: true)
    _ = d.handle(.triggerDown, at: 0)
    _ = d.handle(.triggerUp, at: 0.1)
    _ = d.handle(.triggerDown, at: 0.2)
    _ = d.handle(.otherKey, at: 0.25)  // ⌥e on the second press
    #expect(d.handle(.triggerUp, at: 0.3) == nil)
    #expect(d.tick(at: 1) == nil)
}

@Test func slowReleaseIgnoredWhenHoldOff() {
    var d = TapDetector(doubleTap: true, hold: false)
    #expect(d.handle(.triggerDown, at: 0) == nil)
    #expect(d.nextDeadline == nil)
    #expect(d.handle(.triggerUp, at: 0.38) == nil)
    #expect(d.tick(at: 1) == nil)
}

@Test func typingDuringDoubleTapWaitCancels() {
    var d = TapDetector(doubleTap: true, hold: true)
    _ = d.handle(.triggerDown, at: 0)
    _ = d.handle(.triggerUp, at: 0.1)
    #expect(d.handle(.otherKey, at: 0.2) == nil)
    #expect(d.tick(at: 0.5) == nil)
    var m = TapDetector(doubleTap: true, hold: true)
    _ = m.handle(.triggerDown, at: 0)
    _ = m.handle(.triggerUp, at: 0.1)
    #expect(m.handle(.mouse, at: 0.2) == nil)
    #expect(m.tick(at: 0.5) == nil)
}

@Test func tapInOpenPopoverDoesNotWaitForSecondTap() {
    var detector = TapDetector(doubleTap: true, hold: true)
    #expect(detector.handle(.triggerDown, at: 0) == nil)
    #expect(detector.handle(.triggerUp, at: 0.1, allowsDoubleTap: false) == .singleTap)
    #expect(detector.nextDeadline == nil)
}
