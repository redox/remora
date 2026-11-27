import Testing
import Foundation
import Storage
@testable import LLM

@Suite struct UsageDashboardTests {
    static let paris: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Paris")!
        return c
    }()
    static let posix = Locale(identifier: "en_US")

    static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        paris.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    static func call(at: Date = date(2026, 11, 23, 9), job: String = "chat", model: String = "gpt-6-luna",
                     backend: String = "siwc", status: LLMCallStatus = .completed, errorCode: String? = nil,
                     input: Int = 1000, cached: Int = 0, output: Int = 100, cost: Double? = nil) -> LLMCall {
        LLMCall(startedAt: at, durationMs: 10, backend: backend, model: model, jobType: job, status: status,
                errorCode: errorCode, inputTokens: input, cachedInputTokens: cached, outputTokens: output,
                estCostUSD: cost)
    }

    @Test func everyJobTypeHasACategoryAndAHumanLabel() {
        for j in JobType.allCases {
            #expect(UsageLabels.job(j.rawValue) != j.rawValue, "\(j.rawValue)")
            _ = UsageCategory.of(jobType: j.rawValue)
        }
        #expect(UsageLabels.job("hour_chronicle") == "Hour summary")
        #expect(UsageLabels.job("rewrite") == "Rewrite")
        #expect(UsageLabels.job("edit_mode") == "Draft and Rewrite")
        #expect(UsageLabels.job("chat") == "Chat")
        #expect(UsageLabels.job("dictation_cleanup") == "Dictation cleanup")
        #expect(UsageCategory.of(jobType: "rewrite") == .writing)
        #expect(UsageCategory.of(jobType: "chat_fold") == .chat)
        #expect(UsageCategory.of(jobType: "nudge_write") == .briefs)
        #expect(UsageCategory.of(jobType: "hour_chronicle") == .memory)
        #expect(UsageCategory.allCases.map(\.title) == ["Writing", "Chat", "Memory", "Briefs & nudges"])
        #expect(UsageRange.allCases.map(\.title) == ["Today", "7 days", "30 days"])
    }

    @Test func unknownJobTypeFallsBackToMemoryAndWords() {
        #expect(UsageCategory.of(jobType: "some_new_job") == .memory)
        #expect(UsageLabels.job("some_new_job") == "Some new job")
        #expect(UsageLabels.artifact(table: "nope", job: "x") == "a memory item")
        #expect(UsageLabels.artifact(table: "wiki_pages", job: "wiki_writeup") == "a wiki page")
    }

    @Test func zeroTokenCallsCostNothing() {
        let priced = Self.call(cost: 0.5)
        let empty = Self.call(status: .failed, input: 0, output: 0)
        #expect(UsageCost.effective(empty) == 0)
        let s = UsageDashboard.summarize([priced, empty])
        #expect(s.unpricedCalls == 0)
        #expect(s.costUSD == 0.5)
        #expect(s.tokens == 1100)
    }

    @Test func unpricedCallWithTokensMakesALowerBound() {
        let s = UsageDashboard.summarize([Self.call(cost: 0.1), Self.call()])
        #expect(s.unpricedCalls == 1)
        #expect(UsageCost.effective(Self.call()) == nil)
        #expect(UsageDashboard.costText(s.costUSD, lowerBound: s.unpricedCalls > 0, locale: Self.posix) == "≥ $0.10")
    }

    @Test func summaryCountsLimitsAndFailuresSeparately() {
        let s = UsageDashboard.summarize([
            Self.call(status: .limit), Self.call(status: .failed, errorCode: "usage_limit"),
            Self.call(status: .failed), Self.call(status: .completed), Self.call(status: .cancelled),
        ])
        #expect(s.calls == 5)
        #expect(s.usageLimits == 2)
        #expect(s.failures == 1)
        #expect(UsageLabels.status(Self.call(status: .limit)) == "Usage limit")
        #expect(UsageLabels.status(Self.call(status: .failed)) == "Failed")
        #expect(UsageLabels.status(Self.call(status: .cancelled)) == "Cancelled")
        #expect(UsageLabels.status(Self.call()) == "OK")
    }

    @Test func weekRangeStartsSixMidnightsAgoAcrossDST() {
        let now = Self.date(2026, 3, 31, 10)
        let i = UsageRange.week.interval(now: now, calendar: Self.paris)
        #expect(i.start == Self.date(2026, 3, 25))
        #expect(i.end == now)
        #expect(UsageRange.today.interval(now: now, calendar: Self.paris).start == Self.date(2026, 3, 31))
        #expect(UsageRange.month.interval(now: now, calendar: Self.paris).start == Self.date(2026, 3, 2))
        #expect(UsageRange.today.bucket == .hour)
        #expect(UsageRange.week.bucket == .day)
    }

    @Test func todayBucketsByHourAndCategory() {
        let now = Self.date(2026, 11, 23, 12)
        let calls = [
            Self.call(at: Self.date(2026, 11, 23, 9, 5), job: "chat", cost: 0.1),
            Self.call(at: Self.date(2026, 11, 23, 9, 50), job: "chat_fold", cost: 0.2),
            Self.call(at: Self.date(2026, 11, 23, 9, 20), job: "rewrite", cost: 0.3),
            Self.call(at: Self.date(2026, 11, 23, 10, 1), job: "hour_chronicle", cost: 0.4),
            Self.call(at: Self.date(2026, 11, 22, 23), job: "chat", cost: 9),
        ]
        let b = UsageDashboard.buckets(calls, range: .today, now: now, calendar: Self.paris)
        #expect(b.map(\.category) == [.writing, .chat, .memory])
        #expect(b.map(\.start) == [Self.date(2026, 11, 23, 9), Self.date(2026, 11, 23, 9), Self.date(2026, 11, 23, 10)])
        #expect(abs(b[1].costUSD - 0.3) < 1e-9)
        #expect(b[1].tokens == 2200)
    }

    @Test func breakdownSortsByCostThenTokens() {
        let rows = UsageDashboard.breakdown([
            Self.call(job: "chat", input: 10, output: 0, cost: 1),
            Self.call(job: "rewrite", input: 500, output: 0, cost: 1),
            Self.call(job: "identity", input: 5, output: 0, cost: 2),
            Self.call(job: "nudge_write", input: 7, output: 0),
        ], by: .job)
        #expect(rows.map(\.key) == ["identity", "rewrite", "chat", "nudge_write"])
        #expect(rows[0].label == "Identity")
        #expect(abs(rows[0].share - 0.5) < 1e-9)
        #expect(rows[3].unpricedCalls == 1)
        let byModel = UsageDashboard.breakdown([Self.call(model: "m1", cost: 1)], by: .model)
        #expect(byModel[0].label == "m1")
    }

    @Test func breakdownShareFallsBackToTokensWhenNothingIsPriced() {
        let rows = UsageDashboard.breakdown([
            Self.call(job: "chat", input: 300, output: 0), Self.call(job: "rewrite", input: 100, output: 0),
        ], by: .job)
        #expect(rows.map(\.key) == ["chat", "rewrite"])
        #expect(abs(rows[0].share - 0.75) < 1e-9)
    }

    @Test func filterByCategoryJobModelAndProblems() {
        let chat = Self.call(job: "chat", model: "a")
        let rewrite = Self.call(job: "rewrite", model: "b", status: .failed)
        #expect(UsageFilter(category: .chat).matches(chat))
        #expect(!UsageFilter(category: .chat).matches(rewrite))
        #expect(UsageFilter(job: "rewrite").matches(rewrite))
        #expect(!UsageFilter(job: "rewrite").matches(chat))
        #expect(UsageFilter(model: "a").matches(chat))
        #expect(!UsageFilter(model: "a").matches(rewrite))
        #expect(UsageFilter(problemsOnly: true).matches(rewrite))
        #expect(UsageFilter(problemsOnly: true).matches(Self.call(status: .limit)))
        #expect(!UsageFilter(problemsOnly: true).matches(chat))
        #expect(UsageFilter().matches(chat))
    }

    @Test func compactTokenFormatting() {
        let l = Self.posix
        #expect(UsageDashboard.compactTokens(950, locale: l) == "950")
        #expect(UsageDashboard.compactTokens(12_400, locale: l) == "12.4k")
        #expect(UsageDashboard.compactTokens(841_000, locale: l) == "841k")
        #expect(UsageDashboard.compactTokens(1_250_000, locale: l) == "1.25M")
        #expect(UsageDashboard.compactTokens(0, locale: l) == "0")
    }

    @Test func costTextFormatting() {
        let l = Self.posix
        #expect(UsageDashboard.costText(0.29, lowerBound: false, locale: l) == "$0.29")
        #expect(UsageDashboard.costText(0.0031, lowerBound: false, locale: l) == "$0.0031")
        #expect(UsageDashboard.costText(0, lowerBound: false, locale: l) == "$0")
        #expect(UsageDashboard.costText(0.29, lowerBound: true, locale: l) == "≥ $0.29")
        #expect(UsageDashboard.costText(1_234.5, lowerBound: false, locale: l) == "$1,234.50")
    }

    @Test func costTextUsesTheLocaleDecimalSeparatorLikeTheOtherFigures() {
        let fr = Locale(identifier: "fr_FR")
        #expect(UsageDashboard.costText(0.29, lowerBound: false, locale: fr) == "$0,29")
        #expect(UsageDashboard.costText(0.0024, lowerBound: false, locale: fr) == "$0,0024")
        #expect(UsageDashboard.costText(0.00001, lowerBound: false, locale: fr) == "<$0,0001")
    }

    @Test func lowerBoundNeverPrefixesTheBelowSign() {
        let l = Self.posix
        #expect(UsageDashboard.costText(0.00001, lowerBound: false, locale: l) == "<$0.0001")
        #expect(UsageDashboard.costText(0.00001, lowerBound: true, locale: l) == "≥ $0")
        #expect(UsageDashboard.costText(0, lowerBound: true, locale: l) == "≥ $0")
    }

    @Test func callTimeIsShortEnoughForItsColumn() {
        let gb = Locale(identifier: "en_GB")
        let now = Self.date(2026, 11, 23, 20, 0)
        let earlierToday = Self.date(2026, 11, 23, 19, 59)
        let sunday = Self.date(2026, 11, 22, 19, 59)
        #expect(UsageLabels.time(earlierToday, range: .today, now: now, calendar: Self.paris, locale: gb) == "19:59")
        #expect(UsageLabels.time(earlierToday, range: .week, now: now, calendar: Self.paris, locale: gb) == "19:59")
        #expect(UsageLabels.time(sunday, range: .week, now: now, calendar: Self.paris, locale: gb) == "Sun 19:59")
        let month = UsageLabels.time(sunday, range: .month, now: now, calendar: Self.paris, locale: gb)
        #expect(month == "22 Nov 19:59")
    }

    @Test func problemsTextCountsLimitsAndFailures() {
        var s = UsageSummary()
        #expect(UsageDashboard.problemsText(s) == "None")
        s.usageLimits = 1
        #expect(UsageDashboard.problemsText(s) == "1 limit")
        s.usageLimits = 3; s.failures = 1
        #expect(UsageDashboard.problemsText(s) == "3 limits · 1 failed")
        s.usageLimits = 0
        #expect(UsageDashboard.problemsText(s) == "1 failed")
    }

    @Test func callLabelsForTheLogAndDetail() {
        var c = Self.call(model: "gpt-6-luna", input: 12_410, cached: 2_560, output: 380)
        c.reasoningTokens = 120
        c.reasoningEffort = "low"
        #expect(UsageLabels.tokens(c, locale: Self.posix) == "12.4k → 380")
        #expect(UsageLabels.tokenBreakdown(c, locale: Self.posix)
            == "Input 12,410 (2,560 cached) · Output 380 (120 reasoning)")
        #expect(UsageLabels.backend("siwc") == "ChatGPT")
        #expect(UsageLabels.backend("on_device") == "On-device")
        #expect(UsageLabels.backend("api_key") == "API key")
        #expect(UsageLabels.backend("other") == "other")
    }

    @Test func durationIsShortAndReadable() {
        #expect(UsageLabels.duration(ms: 420, locale: Self.posix) == "0.4 s")
        #expect(UsageLabels.duration(ms: 2_100, locale: Self.posix) == "2.1 s")
        #expect(UsageLabels.duration(ms: 12_345, locale: Self.posix) == "12 s")
        #expect(UsageLabels.duration(ms: 65_000, locale: Self.posix) == "1 min 5 s")
    }

    @Test func clickingABreakdownRowTogglesItsFilter() {
        var f = UsageFilter(category: .memory)
        f = f.toggling(.job, key: "rewrite")
        #expect(f.job == "rewrite" && f.model == nil && f.category == nil)
        f = f.toggling(.model, key: "m")
        #expect(f.job == "rewrite" && f.model == "m")
        f = f.toggling(.job, key: "rewrite")
        #expect(f.job == nil && f.model == "m")
        f = f.toggling(.job, key: "chat").toggling(.job, key: "rewrite")
        #expect(f.job == "rewrite")
    }

    @Test func choosingACategoryClearsTheJobFilter() {
        let f = UsageFilter(job: "rewrite", model: "m").selecting(category: .chat)
        #expect(f.category == .chat && f.job == nil && f.model == "m")
        #expect(f.selecting(job: "chat").category == nil)
    }

    @Test func explanationMatchesPriceTableCost() {
        let table = PriceTable(models: ["m": ModelPrice(inputPer1M: 0.25, cachedInputPer1M: 0.025, outputPer1M: 2)])
        let c = Self.call(model: "m", input: 12_410, cached: 2_560, output: 380)
        let text = UsageCost.explanation(c, prices: table, locale: Self.posix)
        let total = table.cost(model: "m", usage: LLMUsage(inputTokens: 12_410, cachedInputTokens: 2_560, outputTokens: 380, reasoningTokens: 0), backend: .siwc)!
        #expect(text == "9,850 input × $0.25 + 2,560 cached × $0.025 + 380 output × $2.00 per 1M ≈ \(UsageDashboard.costText(total, lowerBound: false, locale: Self.posix))")
        #expect(text?.hasSuffix("≈ $0.0033") == true)
        #expect(UsageCost.explanation(Self.call(model: "unknown"), prices: table, locale: Self.posix) == nil)
    }

    @Test func explanationUsesLongContextRatesAboveThreshold() {
        let table = PriceTable.builtIn
        let c = Self.call(model: "gpt-6-luna", input: 300_000, cached: 0, output: 1_000)
        let text = UsageCost.explanation(c, prices: table, locale: Self.posix)
        #expect(text?.contains("300,000 input × $0.20") == true)
        #expect(text?.contains("1,000 output × $0.75") == true)
    }

    @Test func onDeviceCallsExplainAsFree() {
        let c = Self.call(backend: "on_device", cost: 0)
        #expect(UsageCost.explanation(c, prices: .empty, locale: Self.posix) == "On-device: free")
    }

    @Test func legendClickTogglesTheCategory() {
        let f = UsageFilter(job: "rewrite").toggling(category: .chat)
        #expect(f.category == .chat && f.job == nil)
        #expect(f.toggling(category: .chat).category == nil)
        #expect(f.toggling(category: .memory).category == .memory)
    }

    @Test func chartDomainRunsToTheEndOfToday() {
        let now = Self.date(2026, 11, 23, 14, 5)
        let today = UsageRange.today.chartDomain(now: now, calendar: Self.paris)
        #expect(today.start == Self.date(2026, 11, 23) && today.end == Self.date(2026, 11, 24))
        let week = UsageRange.week.chartDomain(now: now, calendar: Self.paris)
        #expect(week.start == Self.date(2026, 11, 17) && week.end == Self.date(2026, 11, 24))
    }

    @Test func detailLinesDescribeTheCallWithoutContent() {
        var c = Self.call(model: "m", input: 1000, output: 100)
        c.durationMs = 2_100
        #expect(UsageLabels.facts(c, locale: Self.posix) == "Effort default · Backend ChatGPT · Duration 2.1 s")
        c.reasoningEffort = "low"
        #expect(UsageLabels.facts(c, locale: Self.posix) == "Effort low · Backend ChatGPT · Duration 2.1 s")
        let table = PriceTable(models: ["m": ModelPrice(inputPer1M: 1, cachedInputPer1M: 0.1, outputPer1M: 2)])
        #expect(UsageCost.detailLine(c, prices: table, locale: Self.posix)
            == "Cost: " + UsageCost.explanation(c, prices: table, locale: Self.posix)!)
        #expect(UsageCost.detailLine(c, prices: .empty, locale: Self.posix) == "Cost: the price table has no price for m.")
    }

    /// Rollups link to `chronicle` too, so the job type says which summary it was.
    @Test func chronicleArtifactsAreNamedByTheirJob() {
        #expect(UsageLabels.artifact(table: "chronicle", job: "hour_chronicle") == "an hour summary")
        #expect(UsageLabels.artifact(table: "chronicle", job: "day_rollup") == "a day summary")
        #expect(UsageLabels.artifact(table: "chronicle", job: "week_rollup") == "a week summary")
        #expect(UsageLabels.artifact(table: "chronicle", job: "month_rollup") == "a month summary")
        #expect(UsageLabels.artifact(table: "chronicle", job: "year_rollup") == "a year summary")
        #expect(UsageLabels.artifact(table: "chronicle", job: "other") == "a chronicle summary")
    }
}
