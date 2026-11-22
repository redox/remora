import Foundation

public enum PauseDuration: CaseIterable, Sendable {
    case minutes15, hour1, untilTomorrow, indefinitely

    /// End of the pause. "Until tomorrow" is 08:00 on the next calendar day (never today's).
    public func end(from now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .minutes15: return now.addingTimeInterval(15 * 60)
        case .hour1: return now.addingTimeInterval(60 * 60)
        case .indefinitely: return .distantFuture
        case .untilTomorrow:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
            return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow)
                ?? now.addingTimeInterval(24 * 3600)
        }
    }
}
