import Foundation
import Storage
import Testing
@testable import LLM

@Test func accountSectionsAndOffers() {
    let cases: [(SignInState, AccountPresentation.Section, Bool, Bool, Bool, String)] = [
        (.unavailable, .unavailable, false, false, true, "ChatGPT: can't read sign-in"),
        (.signedOut, .signedOut, true, false, false, "ChatGPT: not signed in"),
        (.needsSignIn, .needsSignIn, true, true, false, "ChatGPT: sign in again"),
        (.signedIn(email: "a@b.c", planUsageEnabled: true), .signedIn(email: "a@b.c"), false, true, false, "ChatGPT: signed in"),
        (.signedIn(email: nil, planUsageEnabled: false), .planUsageMissing(email: nil), true, true, false, "ChatGPT: plan usage off"),
    ]
    for (state, section, continues, signOut, retry, line) in cases {
        let p = AccountPresentation(state)
        #expect(p.section == section)
        #expect(p.offersContinue == continues)
        #expect(p.offersSignOut == signOut)
        #expect(p.offersRetry == retry)
        #expect(p.menuLine == line)
    }
}

@Test func unavailableNeverOffersSignIn() {
    let p = AccountPresentation(.unavailable)
    #expect(!p.offersContinue && p.offersRetry)
    #expect(AccountPresentation.unavailableMessage == "Can't read your sign-in from the Keychain")
}

@Test func signInErrorsMapToFriendlyCopy() {
    #expect(AccountPresentation.message(for: AuthError.identityMismatch) == "Sign out first to switch ChatGPT accounts.")
    #expect(AccountPresentation.message(for: CancellationError()) == nil)
    #expect(AccountPresentation.message(for: LLMError.temporarilyUnavailable(code: "credential_store"))?.contains("Keychain") == true)
    #expect(AccountPresentation.message(for: AuthError.timedOut)?.contains("timed out") == true)
    // No server text or codes leak.
    #expect(AccountPresentation.message(for: AuthError.authorizationFailed("secret-code")) == "Sign-in could not be verified. Try again.")
    #expect(AccountPresentation.message(for: AuthError.tokenEndpoint(status: 500, code: "x"))?.contains("x") == false)
}

private func totals(cost: Double?, unpriced: Int, calls: Int = 3) -> UsageTotals {
    UsageTotals(key: "k", calls: calls, inputTokens: 1200, cachedInputTokens: 400, outputTokens: 300, reasoningTokens: 120,
                estCostUSD: cost, unpricedCalls: unpriced)
}

@Test func costFormatting() {
    #expect(UsagePresentation.cost(totals(cost: nil, unpriced: 3)) == "—")
    #expect(UsagePresentation.cost(totals(cost: 0.5, unpriced: 0)) == "$0.5000")
    #expect(UsagePresentation.cost(totals(cost: 0.5, unpriced: 1)) == "≥ $0.5000")
    #expect(UsagePresentation.cost(totals(cost: 0, unpriced: 0)) == "$0.0000")
}

@Test func tokenFormatting() {
    let t = totals(cost: nil, unpriced: 0)
    #expect(UsagePresentation.input(t, locale: Locale(identifier: "en_US")) == "1,200 (400 cached)")
    #expect(UsagePresentation.output(t, locale: Locale(identifier: "en_US")) == "300 (120 reasoning)")
}

@Test func labels() {
    #expect(UsagePresentation.label("dictation_cleanup", grouping: .job) == "Dictation cleanup")
    #expect(UsagePresentation.label("2026-11-20", grouping: .day) == "2026-11-20")
    #expect(UsagePresentation.label("gpt_x", grouping: .model) == "gpt_x")
}

@Test func dayWindowIsFourteenCalendarDays() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let now = Date(timeIntervalSince1970: 1_700_000_000 + 3600)  // 2023-11-14 23:13 UTC
    let s = UsagePresentation.since(.day, now: now, calendar: cal)
    #expect(cal.dateComponents([.year, .month, .day, .hour], from: s) == DateComponents(year: 2023, month: 11, day: 1, hour: 0))
}

@Test func limitBannerOnlyWithin24Hours() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let utc = TimeZone(identifier: "UTC")!, us = Locale(identifier: "en_US")
    #expect(UsagePresentation.limitBanner(lastLimitAt: nil, now: now, timeZone: utc, locale: us) == nil)
    let recent = UsagePresentation.limitBanner(lastLimitAt: now.addingTimeInterval(-3600), now: now, timeZone: utc, locale: us)
    #expect(recent?.hasPrefix("Usage limit reached at ") == true)
    #expect(UsagePresentation.limitBanner(lastLimitAt: now.addingTimeInterval(-86_401), now: now, timeZone: utc, locale: us) == nil)
    #expect(UsagePresentation.limitBanner(lastLimitAt: now.addingTimeInterval(60), now: now, timeZone: utc, locale: us) == nil)
}

@Test func usageLimitIsRecognisedByStatusOrErrorCode() {
    func call(_ status: LLMCallStatus, _ code: String?) -> LLMCall {
        LLMCall(startedAt: .now, durationMs: 1, backend: "siwc", model: "m", jobType: "rewrite", status: status, errorCode: code)
    }
    let byCode = call(.failed, "usage_limit"), byStatus = call(.limit, nil), plainFail = call(.failed, "http_500")
    #expect(UsagePresentation.isUsageLimit(byCode) && UsagePresentation.isUsageLimit(byStatus) && !UsagePresentation.isUsageLimit(plainFail))
    #expect(UsagePresentation.matches(byCode, .usageLimit) && !UsagePresentation.matches(byCode, .failed))
    #expect(UsagePresentation.matches(plainFail, .failed) && !UsagePresentation.matches(plainFail, .usageLimit))
    #expect(UsagePresentation.matches(plainFail, .all))
    #expect(UsagePresentation.statusLabel(byCode) == "Usage limit reached")
    #expect(UsagePresentation.statusLabel(call(.completed, nil)) == "OK")
    #expect(UsagePresentation.statusLabel(plainFail) == "Failed")
    #expect(UsagePresentation.statusLabel(call(.cancelled, nil)) == "Cancelled")
}
