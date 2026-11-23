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

@Test func pausedNoticeGivesTheBackoffEnd() {
    let utc = TimeZone(identifier: "UTC")!, us = Locale(identifier: "en_US")
    let until = Date(timeIntervalSince1970: 1_700_000_000)  // 22:13 UTC
    let text = UsagePresentation.pausedNotice(until: until, timeZone: utc, locale: us)
    // The time separator before "PM" is a narrow no-break space on current macOS.
    #expect(text.hasPrefix("Background memory paused until 10:13"))
    #expect(text.hasSuffix("PM: ChatGPT usage limit reached."))
}

@Test func footnotesForUnpricedAndCappedCalls() {
    #expect(UsagePresentation.unpricedNote(3) == "3 calls have no price yet.")
    #expect(UsagePresentation.unpricedNote(1) == "1 call has no price yet.")
    #expect(UsagePresentation.callLimit == 5_000)
    #expect(UsagePresentation.cappedNote == "Showing the newest 5,000 calls.")
    #expect(UsagePresentation.emptyRange == "No calls in this range.")
    #expect(UsagePresentation.unreadable == "Usage could not be read.")
}

@Test func activeBackoffNoticeWinsOverTheLimitBanner() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let utc = TimeZone(identifier: "UTC")!, us = Locale(identifier: "en_US")
    let backoff = UsagePresentation.notice(backoffUntil: now.addingTimeInterval(600), lastLimitAt: now.addingTimeInterval(-60),
                                           now: now, timeZone: utc, locale: us)
    #expect(backoff?.hasPrefix("Background memory paused until ") == true)
    let banner = UsagePresentation.notice(backoffUntil: now.addingTimeInterval(-1), lastLimitAt: now.addingTimeInterval(-60),
                                          now: now, timeZone: utc, locale: us)
    #expect(banner?.hasPrefix("Usage limit reached at ") == true)
    #expect(UsagePresentation.notice(backoffUntil: nil, lastLimitAt: nil, now: now) == nil)
}

@Test func footnotesFollowTheSummary() {
    var s = UsageSummary()
    #expect(UsagePresentation.footnotes(s) == [UsagePresentation.caption])
    s.unpricedCalls = 2
    #expect(UsagePresentation.footnotes(s) == [UsagePresentation.caption, "2 calls have no price yet."])
}

@Test func onlyTheTableIsCappedAfterFiltering() {
    func call(_ job: String, _ t: Double) -> LLMCall {
        LLMCall(startedAt: Date(timeIntervalSince1970: t), durationMs: 1, backend: "siwc", model: "m", jobType: job, status: .completed)
    }
    let newestFirst = [call("chat", 5), call("rewrite", 4), call("chat", 3), call("chat", 2), call("rewrite", 1)]
    let chat = UsagePresentation.tableCalls(newestFirst, filter: UsageFilter(job: "chat"), limit: 2)
    #expect(chat.calls.map(\.startedAt.timeIntervalSince1970) == [5, 3])
    #expect(chat.truncated)
    let rewrite = UsagePresentation.tableCalls(newestFirst, filter: UsageFilter(job: "rewrite"), limit: 2)
    #expect(rewrite.calls.count == 2 && !rewrite.truncated)
    #expect(UsagePresentation.tableCalls(newestFirst, filter: UsageFilter()).calls.count == 5)
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
}
