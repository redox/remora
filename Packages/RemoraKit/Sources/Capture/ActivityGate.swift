import Foundation

public enum ActivityGate {
    /// Capture only while the user is active: not idle, screen unlocked, Mac awake.
    public static func shouldTick(idleSeconds: TimeInterval, screenLocked: Bool, asleep: Bool,
                                  idleThreshold: TimeInterval = 60) -> Bool {
        !screenLocked && !asleep && idleSeconds < idleThreshold
    }
}
