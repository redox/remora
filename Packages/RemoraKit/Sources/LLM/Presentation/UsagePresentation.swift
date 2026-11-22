import Foundation
import Storage

/// Formatting for Settings › Usage. Pure, so it is unit-tested.
public enum UsagePresentation {
    public static let caption = "Cost is an API-equivalent estimate, not a bill."
    public static let priceNote = "Prices are API-equivalent estimates, and the price table ships empty: a model without an entry shows \"—\". Edit the price table to add per-1M-token prices."

    public enum Grouping: String, Sendable, CaseIterable, Identifiable {
        case day, job, model
        public var id: String { rawValue }
        public var title: String {
            switch self { case .day: "By day"; case .job: "By job"; case .model: "By model" }
        }
        /// "By day" covers the last 14 days.
        public static let dayWindow = 14
    }

    /// `$0.0000`; "—" when no row is priced; "≥ $x" when some rows are unpriced (a lower bound).
    public static func cost(_ t: UsageTotals) -> String {
        guard let c = t.estCostUSD else { return "—" }
        let s = String(format: "$%.4f", c)
        return t.unpricedCalls > 0 ? "≥ \(s)" : s
    }

    public static func tokens(_ n: Int, locale: Locale = .current) -> String {
        n.formatted(.number.grouping(.automatic).locale(locale))
    }

    /// "1,200 (400 cached)".
    public static func input(_ t: UsageTotals, locale: Locale = .current) -> String {
        "\(tokens(t.inputTokens, locale: locale)) (\(tokens(t.cachedInputTokens, locale: locale)) cached)"
    }
    /// "300 (120 reasoning)".
    public static func output(_ t: UsageTotals, locale: Locale = .current) -> String {
        "\(tokens(t.outputTokens, locale: locale)) (\(tokens(t.reasoningTokens, locale: locale)) reasoning)"
    }

    /// "dictation_cleanup" -> "Dictation cleanup"; other keys (dates, model slugs) are unchanged.
    public static func label(_ key: String, grouping: Grouping) -> String {
        guard grouping == .job else { return key }
        let words = key.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// The window start for a grouping (midnight `dayWindow - 1` days ago for days; 30 days otherwise).
    public static func since(_ g: Grouping, now: Date, calendar: Calendar = .current) -> Date {
        switch g {
        case .day: return calendar.date(byAdding: .day, value: -(Grouping.dayWindow - 1), to: calendar.startOfDay(for: now)) ?? now
        case .job, .model: return calendar.date(byAdding: .day, value: -30, to: now) ?? now
        }
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

    // MARK: Recent calls

    public enum CallFilter: String, Sendable, CaseIterable, Identifiable {
        case all, usageLimit, failed
        public var id: String { rawValue }
        public var title: String {
            switch self { case .all: "All"; case .usageLimit: "Usage limit"; case .failed: "Failed" }
        }
    }

    /// A call counts as a usage-limit hit by its stored status or its error code.
    public static func isUsageLimit(_ c: LLMCall) -> Bool { c.status == .limit || c.errorCode == "usage_limit" }

    public static func matches(_ c: LLMCall, _ f: CallFilter) -> Bool {
        switch f {
        case .all: return true
        case .usageLimit: return isUsageLimit(c)
        case .failed: return c.status == .failed && !isUsageLimit(c)
        }
    }

    public static func statusLabel(_ c: LLMCall) -> String {
        if isUsageLimit(c) { return "Usage limit reached" }
        switch c.status {
        case .completed: return "OK"
        case .failed: return "Failed"
        case .limit: return "Usage limit reached"
        case .cancelled: return "Cancelled"
        }
    }
}
