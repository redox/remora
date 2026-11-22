import Testing
@testable import Capture

@Test(arguments: [(10.0, false, false, true), (120.0, false, false, false),
                  (5.0, true, false, false), (5.0, false, true, false)])
func gate(idle: Double, locked: Bool, asleep: Bool, expected: Bool) {
    #expect(ActivityGate.shouldTick(idleSeconds: idle, screenLocked: locked, asleep: asleep) == expected)
}
