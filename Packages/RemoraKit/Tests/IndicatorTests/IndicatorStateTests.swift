import Testing
@testable import Capture
@testable import Indicator

private let safari = "com.apple.Safari"

@Test func capturingSlack() {
    let st = IndicatorState.reduce(input(front("Slack", pid: 1),
        seen(ctx(app: "Slack"), pid: 1, window: 7, verdict: .allowed)))
    #expect(st.status == .capturing && st.displayName == "Slack" && st.window == 7)
    #expect(IndicatorCopy.label(st) == "Capturing Slack")
    #expect(st.dot(previous: nil) == .capturing)
}

@Test func passwordManagerIsKnownBeforeFirstSample() {
    let st = IndicatorState.reduce(input(
        front("1Password", pid: 2, bundleID: "com.1password.1password", verdict: .passwordManager),
        seen(ctx(app: "Slack"), pid: 1, window: 7, verdict: .allowed)))
    #expect(st.status == .notCapturing(.passwordManager) && st.appName == "1Password")
    #expect(st.dot(previous: .capturing) == .notCapturing)
    #expect(IndicatorCopy.label(st) == "Not capturing 1Password")
    #expect(IndicatorCopy.headline(st) == "Not capturing 1Password — password manager")
}

@Test func appLevelUserRuleIsKnownBeforeFirstSample() {
    let st = IndicatorState.reduce(input(
        front("Slack", pid: 2, verdict: .userExcluded(pattern: "app:Slack")), nil))
    #expect(st.status == .notCapturing(.userExcluded(pattern: "app:Slack")))
}

@Test func staleSampleIsPending() {
    let st = IndicatorState.reduce(input(front("Mail", pid: 3),
        seen(ctx(app: "Slack"), pid: 1, window: 7, verdict: .allowed)))
    #expect(st.status == .pending && st.appName == "Mail" && IndicatorCopy.label(st) == nil)
    #expect(st.dot(previous: .capturing) == .capturing)
    #expect(st.dot(previous: nil) == .notCapturing)
}

@Test func remoraFrontmostIsUnknown() {
    let st = IndicatorState.reduce(input(nil,
        seen(ctx(app: "Slack"), pid: 1, window: 7, verdict: .allowed)))
    #expect(st.status == .unknown && st.appName == nil && IndicatorCopy.label(st) == nil)
    #expect(st.dot(previous: .capturing) == .notCapturing)
}

@Test func noAccessibilityWins() {
    let st = IndicatorState.reduce(input(paused: true, ax: false, front("Slack", pid: 1), nil))
    #expect(st == IndicatorState(status: .noAccessibility))
    #expect(st.dot(previous: .capturing) == nil && IndicatorCopy.label(st) == nil)
}

@Test func pausedUsesWorkspaceName() {
    let st = IndicatorState.reduce(input(paused: true, front("Slack", pid: 1), nil))
    #expect(st.status == .paused && st.pid == 1 && st.window == nil && st.site == nil)
    #expect(IndicatorCopy.label(st) == "Not capturing Slack (paused)")
    #expect(st.dot(previous: .capturing) == nil)
}

@Test func browserShowsSiteWithoutWWW() {
    let c = ctx(bundleID: safari, url: "https://www.github.com/x")
    let st = IndicatorState.reduce(input(front("Safari", pid: 4, bundleID: safari),
        seen(c, pid: 4, window: 1, verdict: .allowed)))
    #expect(st.site == "github.com" && IndicatorCopy.label(st) == "Capturing github.com")
}

@Test func privateWindowNeverShowsSite() {
    let c = ctx(bundleID: safari, url: "https://secret.example", privateBrowsing: true)
    let st = IndicatorState.reduce(input(front("Safari", pid: 4, bundleID: safari),
        seen(c, pid: 4, window: 1, verdict: .privateWindow)))
    #expect(st.site == nil && IndicatorCopy.label(st) == "Not capturing Safari")
}

@Test func nonBrowserNeverShowsSite() {
    let st = IndicatorState.reduce(input(front("Notes", pid: 5),
        seen(ctx(app: "Notes", url: "https://x.com"), pid: 5, window: 1, verdict: .allowed)))
    #expect(st.site == nil)
}

@Test(arguments: [
    (CaptureVerdict.privateWindow, "private window"), (.unknownURL, "page address unknown"),
    (.passwordManager, "password manager"), (.sensitiveSite, "banking or password site"),
    (.signInPage, "sign-in page"), (.userExcluded(pattern: "x"), "on your ignore list"),
    (.rulesUnavailable, "ignore list unreadable"),
])
func reasons(v: CaptureVerdict, text: String) { #expect(IndicatorCopy.reason(v) == text) }

@Test func allowedHasNoReason() { #expect(IndicatorCopy.reason(.allowed) == nil) }

// MARK: Announcer

@Test func firstStateIsBaselineOnly() {
    var a = IndicatorAnnouncer()
    #expect(a.update(s(.capturing, "Slack", pid: 1, window: 7)) == nil)
}

@Test func excludedAppSwitchIsSilentAndReturningToCaptureAnnounces() {
    var a = IndicatorAnnouncer()
    _ = a.update(s(.capturing, "Slack", pid: 1, window: 7))
    #expect(a.update(s(.notCapturing(.passwordManager), "1Password", pid: 2)) == nil)
    #expect(a.update(s(.capturing, "Slack", pid: 1, window: 7)) == "Capturing Slack")
}

@Test func windowSwitchAnnounces() {
    var a = IndicatorAnnouncer()
    _ = a.update(s(.capturing, "Slack", pid: 1, window: 7))
    #expect(a.update(s(.capturing, "Slack", pid: 1, window: 8)) == "Capturing Slack")
}

@Test func sameWindowTitleChangeIsSilent() {
    var a = IndicatorAnnouncer()
    _ = a.update(s(.capturing, "Slack", pid: 1, window: 7))
    #expect(a.update(s(.capturing, "Slack", pid: 1, window: 7)) == nil)
}

@Test func sameWindowTabToExcludedSiteIsSilent() {
    var a = IndicatorAnnouncer()
    _ = a.update(s(.capturing, "Safari", pid: 1, window: 1, site: "github.com"))
    #expect(a.update(s(.notCapturing(.sensitiveSite), "Safari", pid: 1, window: 1, site: "boursorama.com"))
            == nil)
}

@Test func sameWindowTabSameBucketIsSilent() {
    var a = IndicatorAnnouncer()
    _ = a.update(s(.capturing, "Safari", pid: 1, window: 1, site: "github.com"))
    #expect(a.update(s(.capturing, "Safari", pid: 1, window: 1, site: "news.ycombinator.com")) == nil)
}

@Test func unknownURLWithinWindowIsSilent() {
    var a = IndicatorAnnouncer()
    _ = a.update(s(.capturing, "Safari", pid: 1, window: 1, site: "github.com"))
    #expect(a.update(s(.notCapturing(.unknownURL), "Safari", pid: 1, window: 1)) == nil)
    #expect(a.update(s(.capturing, "Safari", pid: 1, window: 1, site: "github.com")) == nil)
}

@Test func provisionalThenSampleIsSilent() {
    var a = IndicatorAnnouncer()
    _ = a.update(s(.notCapturing(.passwordManager), "1Password", pid: 2))
    #expect(a.update(s(.notCapturing(.passwordManager), "1Password", pid: 2, window: 9)) == nil)
}

@Test func pendingAndUnknownNeverAnnounce() {
    var a = IndicatorAnnouncer()
    _ = a.update(s(.capturing, "Slack", pid: 1, window: 7))
    #expect(a.update(s(.pending, "Mail", pid: 3)) == nil)
    #expect(a.update(.initial) == nil)
    #expect(a.update(s(.capturing, "Mail", pid: 3, window: 2)) == "Capturing Mail")
}

@Test func pausedAppSwitchIsSilentAndResumingAnnounces() {
    var a = IndicatorAnnouncer()
    _ = a.update(s(.capturing, "Slack", pid: 1, window: 7))
    #expect(a.update(s(.paused, "Slack", pid: 1)) == nil)
    #expect(a.update(s(.paused, "Mail", pid: 2)) == nil)
    #expect(a.update(s(.pending, "Mail", pid: 2)) == nil)
    #expect(a.update(s(.capturing, "Mail", pid: 2, window: 4)) == "Capturing Mail")
}

@Test func appOnlyRulesUnavailableIsNotCapturing() {
    let st = IndicatorState.reduce(input(front("Slack", pid: 2, verdict: .rulesUnavailable), nil))
    #expect(st.status == .notCapturing(.rulesUnavailable) && st.appName == "Slack")
    #expect(st.dot(previous: .capturing) == .notCapturing)
}

@Test func appLevelExcludedBrowserIsNotCapturingBeforeFirstSample() {
    let f = front("Safari", pid: 4, bundleID: "com.apple.Safari", verdict: .userExcluded(pattern: "app:Safari"))
    #expect(IndicatorState.reduce(input(f, nil)).status == .notCapturing(.userExcluded(pattern: "app:Safari")))
    let open = front("Safari", pid: 4, bundleID: "com.apple.Safari", verdict: .allowed)
    #expect(IndicatorState.reduce(input(open, nil)).status == .pending)
}

@Test func pausedHasNoDotRegardlessOfFrontmost() {
    #expect(IndicatorState.reduce(input(paused: true, front("Slack", pid: 1), nil)).dot(previous: .capturing) == nil)
}

@Test func rulesUnavailableVerdictIsNeverReused() {
    #expect(!shouldReuseVerdict(.rulesUnavailable))
    #expect(!shouldReuseVerdict(nil))
    #expect(shouldReuseVerdict(.allowed))
    #expect(shouldReuseVerdict(.userExcluded(pattern: "app:X")))
}

@Test func staleVerdictIsNotReused() {
    #expect(!shouldReuseVerdict(.allowed, stale: true))
    #expect(shouldReuseVerdict(.allowed, stale: false))
}
