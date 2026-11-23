import Foundation
import Storage

/// The model behind Settings › Usage: range, totals, chart buckets, breakdown and cost
/// explanations. Pure and content-free (it only sees `LLMCall` accounting rows), so it is unit-tested.

public enum UsageRange: String, CaseIterable, Identifiable, Sendable {
    case today, week, month
    public var id: String { rawValue }
    public var title: String {
        switch self { case .today: "Today"; case .week: "7 days"; case .month: "30 days" }
    }

    /// From local midnight (N-1 midnights ago for the longer ranges) to `now`. Calendar arithmetic, not
    /// 24-hour multiples, so a DST change inside the range does not shift the start.
    public func interval(now: Date, calendar: Calendar) -> DateInterval {
        let midnight = calendar.startOfDay(for: now)
        let days: Int
        switch self { case .today: days = 0; case .week: days = 6; case .month: days = 29 }
        let start = calendar.date(byAdding: .day, value: -days, to: midnight) ?? midnight
        return DateInterval(start: min(start, now), end: now)
    }

    public var bucket: Calendar.Component { self == .today ? .hour : .day }

    /// The chart's x axis: the range's start to the end of today, so today's later hours (or today's
    /// bar) keep their place instead of the chart stretching to the last call.
    public func chartDomain(now: Date, calendar: Calendar) -> DateInterval {
        let start = interval(now: now, calendar: calendar).start
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        return DateInterval(start: start, end: max(start, end))
    }
}

public enum UsageCategory: String, CaseIterable, Identifiable, Sendable {
    case writing, chat, memory, briefs
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .writing: "Writing"
        case .chat: "Chat"
        case .memory: "Memory"
        case .briefs: "Briefs & nudges"
        }
    }

    /// Unknown job types count as memory (background work), so a new job is never dropped from the chart.
    public static func of(jobType: String) -> UsageCategory {
        switch jobType {
        case "rewrite", "edit_mode", "dictation_cleanup": .writing
        case "chat", "chat_fold", "query_expansion": .chat
        case "morning_brief", "evening_wrap", "nudge_triage", "nudge_write", "reminder_prompt": .briefs
        default: .memory
        }
    }
}

public enum UsageLabels {
    public static func job(_ raw: String) -> String {
        switch raw {
        case "hour_chronicle": return "Hour summary"
        case "rewrite": return "Rewrite"
        case "edit_mode": return "Edit mode"
        case "chat": return "Chat"
        case "dictation_cleanup": return "Dictation cleanup"
        case "query_expansion": return "Search expansion"
        case "working_memory": return "Working memory"
        case "salient_flags": return "Highlights"
        case "entity_extraction": return "People and places"
        case "time_ledger_attribution": return "Time ledger"
        case "nudge_triage": return "Nudge triage"
        case "evidence_check": return "Evidence check"
        case "day_rollup": return "Day summary"
        case "week_rollup": return "Week summary"
        case "month_rollup": return "Month summary"
        case "year_rollup": return "Year summary"
        case "wiki_writeup": return "Wiki page"
        case "style_consolidation": return "Writing style"
        case "morning_brief": return "Morning brief"
        case "evening_wrap": return "Evening wrap"
        case "nudge_write": return "Nudge"
        case "memory_digest": return "Memory digest"
        case "chat_fold": return "Chat summary"
        case "reminder_prompt": return "Reminder"
        default:
            let words = raw.replacingOccurrences(of: "_", with: " ")
            return words.prefix(1).uppercased() + words.dropFirst()
        }
    }

    /// "Produced: <this>" wording for the table a call wrote to. Hour summaries and every rollup
    /// write to `chronicle`, so the job type names the level.
    public static func artifact(table: String, job: String) -> String {
        switch table {
        case "chronicle":
            switch job {
            case "hour_chronicle": "an hour summary"
            case "day_rollup": "a day summary"
            case "week_rollup": "a week summary"
            case "month_rollup": "a month summary"
            case "year_rollup": "a year summary"
            default: "a chronicle summary"
            }
        case "wiki_pages": "a wiki page"
        case "working_memory": "a working-memory note"
        case "memory_digest": "a memory digest"
        case "identity": "an identity note"
        case "style_notes": "a style note"
        case "salient_flags": "a highlight"
        case "inline_outputs": "an inline result"
        case "chat_turns": "a chat message"
        case "chat_summaries": "a chat summary"
        case "inbox_messages": "an inbox message"
        default: "a memory item"
        }
    }

    /// A call's time, as short as its range allows so the log's Time column never truncates:
    /// "19:59" for today's calls, "Sun 19:59" in the 7-day range, "22 Nov 19:59" in the 30-day
    /// range. Uses the locale's 12- or 24-hour clock.
    public static func time(_ date: Date, range: UsageRange, now: Date, calendar: Calendar,
                            locale: Locale = .current) -> String {
        func format(_ template: String) -> String {
            let f = DateFormatter()
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            f.locale = locale
            f.setLocalizedDateFormatFromTemplate(template)
            return f.string(from: date)
        }
        let clock = format("jmm")
        if calendar.isDate(date, inSameDayAs: now) { return clock }
        // Day and clock are formatted apart: a combined template adds a word ("at", "à").
        return format(range == .month ? "dMMM" : "EEE") + " " + clock
    }

    /// "12.4k → 380": input then output, compact.
    public static func tokens(_ c: LLMCall, locale: Locale = .current) -> String {
        UsageDashboard.compactTokens(c.inputTokens, locale: locale) + " → "
            + UsageDashboard.compactTokens(c.outputTokens, locale: locale)
    }

    /// "Input 12,410 (2,560 cached) · Output 380 (120 reasoning)".
    public static func tokenBreakdown(_ c: LLMCall, locale: Locale = .current) -> String {
        func n(_ v: Int) -> String { v.formatted(.number.grouping(.automatic).locale(locale)) }
        return "Input \(n(c.inputTokens)) (\(n(c.cachedInputTokens)) cached) · "
            + "Output \(n(c.outputTokens)) (\(n(c.reasoningTokens)) reasoning)"
    }

    public static func backend(_ raw: String) -> String {
        switch LLMBackend(rawValue: raw) {
        case .siwc: "ChatGPT"
        case .onDevice: "On-device"
        case .apiKey: "API key"
        case nil: raw
        }
    }

    /// "0.4 s" and "2.1 s" under ten seconds, "12 s" under a minute, then "1 min 5 s".
    public static func duration(ms: Int, locale: Locale = .current) -> String {
        let seconds = Double(max(0, ms)) / 1000
        if seconds < 10 { return seconds.formatted(.number.precision(.fractionLength(1)).locale(locale)) + " s" }
        let whole = Int(seconds.rounded())
        if whole < 60 { return "\(whole) s" }
        return "\(whole / 60) min \(whole % 60) s"
    }

    /// "Effort low · Backend ChatGPT · Duration 2.1 s" for the selected call.
    public static func facts(_ c: LLMCall, locale: Locale = .current) -> String {
        let effort = c.reasoningEffort.flatMap { $0.isEmpty ? nil : $0 } ?? "default"
        return "Effort \(effort) · Backend \(backend(c.backend)) · Duration \(duration(ms: c.durationMs, locale: locale))"
    }

    public static func status(_ c: LLMCall) -> String {
        if UsagePresentation.isUsageLimit(c) { return "Usage limit" }
        switch c.status {
        case .completed: return "OK"
        case .failed: return "Failed"
        case .limit: return "Usage limit"
        case .cancelled: return "Cancelled"
        }
    }
}

public enum UsageCost {
    /// The stored cost; 0 for a call that used no tokens (a failure before the request left has nothing
    /// to price); nil when tokens were used but no price applied.
    public static func effective(_ c: LLMCall) -> Double? {
        if let cost = c.estCostUSD { return cost }
        return c.inputTokens + c.outputTokens == 0 ? 0 : nil
    }

    /// "9,850 input × $0.25 + 2,560 cached × $0.025 + 380 output × $2.00 per 1M ≈ $0.0031". The rates come
    /// from `PriceTable.rates`, the same lookup `cost` uses; nil when there are none.
    public static func explanation(_ c: LLMCall, prices: PriceTable, locale: Locale = .current) -> String? {
        if LLMBackend(rawValue: c.backend) == .onDevice { return "On-device: free" }
        guard let r = prices.rates(model: c.model, inputTokens: c.inputTokens),
              let input = r.inputPer1M, let output = r.outputPer1M else { return nil }
        let cached = max(0, min(c.cachedInputTokens, c.inputTokens))
        let fresh = c.inputTokens - cached
        func n(_ v: Int) -> String { v.formatted(.number.grouping(.automatic).locale(locale)) }
        var parts = ["\(n(fresh)) input × \(rate(input, locale))"]
        if cached > 0 { parts.append("\(n(cached)) cached × \(rate(r.cachedInputPer1M ?? input, locale))") }
        parts.append("\(n(c.outputTokens)) output × \(rate(output, locale))")
        let usage = LLMUsage(inputTokens: c.inputTokens, cachedInputTokens: c.cachedInputTokens,
                             outputTokens: c.outputTokens, reasoningTokens: c.reasoningTokens)
        guard let total = prices.cost(model: c.model, usage: usage, backend: LLMBackend(rawValue: c.backend) ?? .siwc)
        else { return nil }
        return parts.joined(separator: " + ") + " per 1M ≈ " + UsageDashboard.costText(total, lowerBound: false, locale: locale)
    }

    /// The detail block's cost line, from the current price table.
    public static func detailLine(_ c: LLMCall, prices: PriceTable, locale: Locale = .current) -> String {
        "Cost: " + (explanation(c, prices: prices, locale: locale) ?? "the price table has no price for \(c.model).")
    }

    /// At least two decimals, at most four: $0.25, $0.025, $2.00.
    private static func rate(_ v: Double, _ locale: Locale) -> String {
        "$" + v.formatted(.number.precision(.fractionLength(2...4)).locale(locale))
    }
}

public struct UsageFilter: Equatable, Sendable {
    public var category: UsageCategory?
    public var job: String?
    public var model: String?
    public var problemsOnly: Bool
    public init(category: UsageCategory? = nil, job: String? = nil, model: String? = nil, problemsOnly: Bool = false) {
        self.category = category; self.job = job; self.model = model; self.problemsOnly = problemsOnly
    }

    /// A breakdown row click: sets that job or model filter, or clears it when it is already set.
    /// A job filter replaces the coarser category filter, which could otherwise hide the job.
    public func toggling(_ kind: UsageBreakdownKind, key: String) -> UsageFilter {
        var f = self
        switch kind {
        case .job:
            f.job = job == key ? nil : key
            if f.job != nil { f.category = nil }
        case .model:
            f.model = model == key ? nil : key
        }
        return f
    }

    /// A chart legend click: filters to that category, or clears it when it is already set.
    public func toggling(category c: UsageCategory) -> UsageFilter {
        selecting(category: category == c ? nil : c)
    }

    /// The log's category/job menu: category and job are one choice, so each clears the other.
    public func selecting(category: UsageCategory?) -> UsageFilter {
        var f = self
        f.category = category; f.job = nil
        return f
    }

    public func selecting(job: String?) -> UsageFilter {
        var f = self
        f.job = job; f.category = nil
        return f
    }

    public func matches(_ c: LLMCall) -> Bool {
        if let category, UsageCategory.of(jobType: c.jobType) != category { return false }
        if let job, c.jobType != job { return false }
        if let model, c.model != model { return false }
        if problemsOnly, !(UsagePresentation.isUsageLimit(c) || c.status == .failed) { return false }
        return true
    }
}

public struct UsageSummary: Equatable, Sendable {
    public var calls = 0, tokens = 0, usageLimits = 0, failures = 0, unpricedCalls = 0
    public var costUSD = 0.0
    public init() {}
}

public struct UsageBucket: Equatable, Identifiable, Sendable {
    public var start: Date
    public var category: UsageCategory
    public var costUSD: Double
    public var tokens: Int
    public var id: String { "\(start.timeIntervalSince1970)-\(category.rawValue)" }
}

public enum UsageBreakdownKind: Sendable { case job, model }

public struct UsageBreakdownRow: Equatable, Identifiable, Sendable {
    public var key: String
    public var label: String
    public var calls: Int
    public var tokens: Int
    public var unpricedCalls: Int
    public var costUSD: Double
    public var share: Double
    public var id: String { key }
}

public enum UsageDashboard {
    public static func summarize(_ calls: [LLMCall]) -> UsageSummary {
        var s = UsageSummary()
        for c in calls {
            s.calls += 1
            s.tokens += c.inputTokens + c.outputTokens
            if UsagePresentation.isUsageLimit(c) { s.usageLimits += 1 } else if c.status == .failed { s.failures += 1 }
            if let cost = UsageCost.effective(c) { s.costUSD += cost } else { s.unpricedCalls += 1 }
        }
        return s
    }

    /// One bucket per (bucket start, category) with calls inside the range, by start then category order.
    public static func buckets(_ calls: [LLMCall], range: UsageRange, now: Date, calendar: Calendar) -> [UsageBucket] {
        let interval = range.interval(now: now, calendar: calendar)
        struct Key: Hashable { var start: Date; var category: UsageCategory }
        var acc: [Key: UsageBucket] = [:]
        for c in calls where c.startedAt >= interval.start && c.startedAt <= interval.end {
            guard let start = calendar.dateInterval(of: range.bucket, for: c.startedAt)?.start else { continue }
            let category = UsageCategory.of(jobType: c.jobType)
            let key = Key(start: start, category: category)
            var b = acc[key] ?? UsageBucket(start: start, category: category, costUSD: 0, tokens: 0)
            b.costUSD += UsageCost.effective(c) ?? 0
            b.tokens += c.inputTokens + c.outputTokens
            acc[key] = b
        }
        let order = UsageCategory.allCases
        return acc.values.sorted {
            $0.start != $1.start ? $0.start < $1.start
                : (order.firstIndex(of: $0.category) ?? 0) < (order.firstIndex(of: $1.category) ?? 0)
        }
    }

    /// Cost descending, then tokens descending, then key. `share` is of total cost, or of tokens when
    /// nothing is priced.
    public static func breakdown(_ calls: [LLMCall], by kind: UsageBreakdownKind) -> [UsageBreakdownRow] {
        var rows: [String: UsageBreakdownRow] = [:]
        for c in calls {
            let key = kind == .job ? c.jobType : c.model
            var r = rows[key] ?? UsageBreakdownRow(key: key, label: kind == .job ? UsageLabels.job(key) : key,
                                                  calls: 0, tokens: 0, unpricedCalls: 0, costUSD: 0, share: 0)
            r.calls += 1
            r.tokens += c.inputTokens + c.outputTokens
            if let cost = UsageCost.effective(c) { r.costUSD += cost } else { r.unpricedCalls += 1 }
            rows[key] = r
        }
        let totalCost = rows.values.reduce(0) { $0 + $1.costUSD }
        let totalTokens = rows.values.reduce(0) { $0 + $1.tokens }
        var out = Array(rows.values)
        for i in out.indices {
            if totalCost > 0 { out[i].share = out[i].costUSD / totalCost }
            else if totalTokens > 0 { out[i].share = Double(out[i].tokens) / Double(totalTokens) }
        }
        return out.sorted {
            if $0.costUSD != $1.costUSD { return $0.costUSD > $1.costUSD }
            if $0.tokens != $1.tokens { return $0.tokens > $1.tokens }
            return $0.key < $1.key
        }
    }

    /// 950, 12.4k, 841k, 1.25M: about three significant digits.
    public static func compactTokens(_ n: Int, locale: Locale = .current) -> String {
        func f(_ v: Double) -> String {
            let digits = v < 10 ? 2 : (v < 100 ? 1 : 0)
            return v.formatted(.number.precision(.fractionLength(0...digits)).grouping(.never).locale(locale))
        }
        let v = Double(abs(n))
        let sign = n < 0 ? "-" : ""
        if v < 1_000 { return sign + f(v) }
        if v < 999_500 { return sign + f(v / 1_000) + "k" }
        return sign + f(v / 1_000_000) + "M"
    }

    /// "3 limits · 1 failed"; "None" when there were no problems.
    public static func problemsText(_ s: UsageSummary) -> String {
        var parts: [String] = []
        if s.usageLimits > 0 { parts.append("\(s.usageLimits) limit" + (s.usageLimits == 1 ? "" : "s")) }
        if s.failures > 0 { parts.append("\(s.failures) failed") }
        return parts.isEmpty ? "None" : parts.joined(separator: " · ")
    }

    /// "$0.29" from one cent up, "$0.0031" below, "$0" for nothing; "≥ " when some calls are unpriced.
    /// A lower bound below the smallest shown amount reads "≥ $0", never "≥ <$0.0001".
    /// The number follows `locale` (decimal and grouping separators), like the token counts and
    /// per-million rates beside it; the "$" stays because every price is in US dollars.
    public static func costText(_ usd: Double, lowerBound: Bool, locale: Locale = .current) -> String {
        if lowerBound, usd < 0.00005 { return "≥ $0" }
        func dollars(_ v: Double, _ digits: Int) -> String {
            "$" + v.formatted(.number.grouping(.automatic).precision(.fractionLength(digits)).locale(locale))
        }
        let text: String
        if usd <= 0 { text = "$0" }
        else if usd >= 0.01 { text = dollars(usd, 2) }
        else if usd < 0.00005 { text = "<" + dollars(0.0001, 4) }
        else { text = dollars(usd, 4) }
        return lowerBound ? "≥ " + text : text
    }
}
