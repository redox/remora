import Foundation

/// What one closed hour held: seconds of focused time and how many snapshots were captured.
public struct HourStat: Sendable, Equatable {
    public var hour: DateInterval
    public var focusSeconds: TimeInterval
    public var snapshotCount: Int

    public init(hour: DateInterval, focusSeconds: TimeInterval, snapshotCount: Int) {
        self.hour = hour; self.focusSeconds = focusSeconds; self.snapshotCount = snapshotCount
    }
}

/// One `hour` job's period: one or more consecutive hours. `key` is the first hour's key.
public struct HourSpan: Sendable, Equatable {
    public var start: Date
    public var end: Date
    public var key: String
    public var hours: Int

    public init(start: Date, end: Date, key: String, hours: Int) {
        self.start = start; self.end = end; self.key = key; self.hours = hours
    }
}

/// Groups closed hours into spans, one hour chronicle per span.
///
/// - An hour with neither 60 s of focus nor a snapshot is dropped.
/// - An hour with at least `sparseFocusSeconds` (600 s) of focus is **busy** and is a span of its own.
/// - **Sparse-merge rule:** consecutive (adjacent) sparse hours on one local day merge into one span
///   until the cumulative focus reaches >= 600 s or the span reaches 4 hours; the hour that reaches
///   either limit is the last of its span. A busy hour, a gap, midnight or a limit ends a span.
/// - A sparse span that is still open and ends at the newest closed hour waits: it may still grow
///   with the next hour, so it is planned once the next hour has closed (the caller then passes a
///   later `newestClosedHourEnd`) or 3 hours after its end. It never waits at the end of a day.
public enum HourBatcher {
    public static let sparseFocusSeconds: TimeInterval = 600
    public static let minimumFocusSeconds: TimeInterval = 60
    public static let maximumHours = 4
    public static let trailingWait: TimeInterval = 3 * 3_600

    public struct Batch: Sendable, Equatable {
        public var spans: [HourSpan]
        /// Start of a trailing sparse span that was held back, if any.
        public var waitingFrom: Date?
    }

    public static func plan(_ stats: [HourStat], newestClosedHourEnd: Date, now: Date, calendar: Calendar) -> [HourSpan] {
        batch(stats, newestClosedHourEnd: newestClosedHourEnd, now: now, calendar: calendar).spans
    }

    public static func batch(_ stats: [HourStat], newestClosedHourEnd: Date, now: Date, calendar: Calendar) -> Batch {
        let kept = stats
            .filter { $0.focusSeconds >= minimumFocusSeconds || $0.snapshotCount > 0 }
            .sorted { $0.hour.start < $1.hour.start }
        var spans: [HourSpan] = []
        var run: Run?

        func emit(_ r: Run) {
            spans.append(HourSpan(start: r.start, end: r.end, key: PeriodKey.hourKey(r.start, calendar: calendar), hours: r.hours))
        }

        for stat in kept {
            if stat.focusSeconds >= sparseFocusSeconds {
                if let r = run { emit(r); run = nil }
                emit(Run(start: stat.hour.start, end: stat.hour.end, hours: 1, focus: stat.focusSeconds))
                continue
            }
            if var r = run, r.end == stat.hour.start, calendar.isDate(r.start, inSameDayAs: stat.hour.start) {
                r.end = stat.hour.end; r.hours += 1; r.focus += stat.focusSeconds
                run = r
            } else {
                if let r = run { emit(r) }
                run = Run(start: stat.hour.start, end: stat.hour.end, hours: 1, focus: stat.focusSeconds)
            }
            if let r = run, r.focus >= sparseFocusSeconds || r.hours >= maximumHours { emit(r); run = nil }
        }

        var waitingFrom: Date?
        if let r = run {
            if holdsBack(r, newestClosedHourEnd: newestClosedHourEnd, now: now, calendar: calendar) {
                waitingFrom = r.start
            } else {
                emit(r)
            }
        }
        return Batch(spans: spans, waitingFrom: waitingFrom)
    }

    private struct Run {
        var start: Date
        var end: Date
        var hours: Int
        var focus: TimeInterval
    }

    private static func holdsBack(_ r: Run, newestClosedHourEnd: Date, now: Date, calendar: Calendar) -> Bool {
        guard r.end >= newestClosedHourEnd, now < r.end.addingTimeInterval(trailingWait) else { return false }
        // The next hour starts a new day: nothing can be merged into this span any more.
        return calendar.isDate(r.end.addingTimeInterval(-1), inSameDayAs: r.end.addingTimeInterval(1))
    }
}
