import Foundation

/// When the app's reminder timer should next wake: just after the next firing, and never later
/// than 5 minutes from now (a safety net for a missed wake, clock or time-zone notification).
public enum ReminderArming {
    public static let safetyNet: TimeInterval = 5 * 60
    /// Fires slightly after `next_fire_at`, so `fireDue` sees the reminder as due.
    public static let slack: TimeInterval = 0.5

    public static func delay(nextFireAt: Date?, now: Date) -> TimeInterval {
        guard let next = nextFireAt else { return safetyNet }
        return min(safetyNet, max(0, next.timeIntervalSince(now) + slack))
    }
}
