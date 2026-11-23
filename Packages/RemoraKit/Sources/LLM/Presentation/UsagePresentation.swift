import Foundation
import Storage

/// Copy and notices for Settings › Usage. Pure, so it is unit-tested.
public enum UsagePresentation {
    public static let caption = "Cost is an API-equivalent estimate, not a bill."
    public static let emptyRange = "No calls in this range."
    public static let unreadable = "Usage could not be read."

    /// The log table shows at most this many calls, newest first, so 30 busy days stay responsive.
    /// Totals, chart and breakdown always cover every call in the range.
    public static let callLimit = 5_000
    public static let cappedNote = "Showing the newest \(callLimit.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))) calls."

    /// The footnote behind a "≥" cost.
    public static func unpricedNote(_ n: Int) -> String {
        n == 1 ? "1 call has no price yet." : "\(n) calls have no price yet."
    }

    /// Shown while background memory is backing off after a usage limit.
    public static func pausedNotice(until: Date, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone)
        style.timeZone = timeZone
        return "Background memory paused until \(until.formatted(style)): ChatGPT usage limit reached."
    }

    /// The pane's one notice: an active background backoff wins over a recent usage limit.
    public static func notice(backoffUntil: Date?, lastLimitAt: Date?, now: Date, timeZone: TimeZone = .current,
                              locale: Locale = .current) -> String? {
        if let until = backoffUntil, until > now { return pausedNotice(until: until, timeZone: timeZone, locale: locale) }
        return limitBanner(lastLimitAt: lastLimitAt, now: now, timeZone: timeZone, locale: locale)
    }

    /// The caption, then "N calls have no price yet." behind a "≥" cost.
    public static func footnotes(_ s: UsageSummary) -> [String] {
        var notes = [caption]
        if s.unpricedCalls > 0 { notes.append(unpricedNote(s.unpricedCalls)) }
        return notes
    }

    /// The log's rows: `calls` (newest first) that match `filter`, capped at the newest `limit`.
    /// `truncated` asks for `cappedNote` under the table.
    public static func tableCalls(_ calls: [LLMCall], filter: UsageFilter,
                                  limit: Int = callLimit) -> (calls: [LLMCall], truncated: Bool) {
        var out: [LLMCall] = []
        for c in calls where filter.matches(c) {
            if out.count == limit { return (out, true) }
            out.append(c)
        }
        return (out, false)
    }

    /// "Usage limit reached at 3:05 PM" while `lastLimitAt` is within 24 hours (and not in the future).
    public static func limitBanner(lastLimitAt: Date?, now: Date, timeZone: TimeZone = .current,
                                   locale: Locale = .current) -> String? {
        guard let at = lastLimitAt else { return nil }
        let age = now.timeIntervalSince(at)
        guard age >= 0, age < 86_400 else { return nil }
        var style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone)
        style.timeZone = timeZone
        return "Usage limit reached at \(at.formatted(style))"
    }

    /// A call counts as a usage-limit hit by its stored status or its error code.
    public static func isUsageLimit(_ c: LLMCall) -> Bool { c.status == .limit || c.errorCode == "usage_limit" }
}
