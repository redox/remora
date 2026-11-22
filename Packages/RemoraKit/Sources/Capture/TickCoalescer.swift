/// Bookkeeping for the capture scheduler: never stack ticks, and turn tick outcomes into
/// log-worthy events (a streak of timeouts, reported once per streak; any failure).
public struct TickCoalescer: Sendable {
    public enum Event: Sendable, Equatable {
        case timeoutStreak(Int)
        case failed
    }

    public let timeoutStreakThreshold: Int
    public private(set) var isRunning = false
    private var timeoutStreak = 0

    public init(timeoutStreakThreshold: Int = 5) {
        self.timeoutStreakThreshold = timeoutStreakThreshold
    }

    /// Returns true and marks a tick as running if none is; false means "skip this trigger".
    public mutating func begin() -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        return true
    }

    /// Marks the running tick as finished and returns an event to log, if any.
    public mutating func finish(_ outcome: CaptureOutcome) -> Event? {
        isRunning = false
        guard outcome == .timedOut else {
            timeoutStreak = 0
            return outcome == .failed ? .failed : nil
        }
        timeoutStreak += 1
        return timeoutStreak == timeoutStreakThreshold ? .timeoutStreak(timeoutStreak) : nil
    }
}
