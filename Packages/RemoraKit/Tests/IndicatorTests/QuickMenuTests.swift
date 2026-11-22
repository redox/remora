import Testing
@testable import Capture
@testable import Indicator

@Test func quickMenuCapturingApp() {
    #expect(QuickMenu.items(for: s(.capturing, "Slack", pid: 1, window: 7))
            == [.neverCaptureApp("Slack"), .pause15, .openPrivacySettings])
}

@Test func quickMenuBrowserSite() {
    #expect(QuickMenu.items(for: s(.capturing, "Safari", pid: 1, window: 1, site: "github.com"))
            == [.neverCaptureApp("Safari"), .neverCaptureSite("github.com"), .pause15, .openPrivacySettings])
}

@Test func quickMenuHidesNoOps() {
    #expect(QuickMenu.items(for: s(.notCapturing(.passwordManager), "1Password", pid: 2))
            == [.pause15, .openPrivacySettings])
    #expect(QuickMenu.items(for: s(.notCapturing(.userExcluded(pattern: "app:Slack")), "Slack", pid: 2))
            == [.pause15, .openPrivacySettings])
    #expect(QuickMenu.items(for: s(.notCapturing(.userExcluded(pattern: "github.com")), "Safari", pid: 1, window: 1, site: "github.com"))
            == [.neverCaptureApp("Safari"), .pause15, .openPrivacySettings])
    #expect(QuickMenu.items(for: s(.notCapturing(.sensitiveSite), "Safari", pid: 1, window: 1, site: "boursorama.com"))
            == [.neverCaptureApp("Safari"), .pause15, .openPrivacySettings])
}

@Test func quickMenuWhilePaused() {
    #expect(QuickMenu.items(for: s(.paused, "Slack", pid: 1))
            == [.neverCaptureApp("Slack"), .resume, .openPrivacySettings])
}

@Test func quickMenuForUnknownAndNoAccessibility() {
    #expect(QuickMenu.items(for: .initial) == [.pause15, .openPrivacySettings])
    #expect(QuickMenu.items(for: s(.pending, "Mail", pid: 3)) == [.pause15, .openPrivacySettings])
    #expect(QuickMenu.items(for: IndicatorState(status: .noAccessibility)) == [.openPrivacySettings])
}

@Test func titles() {
    #expect(QuickMenuItem.neverCaptureApp("x").title == "Never capture this app")
    #expect(QuickMenuItem.neverCaptureSite("x").title == "Never capture this site")
    #expect(QuickMenuItem.pause15.title == "Pause 15 min")
    #expect(QuickMenuItem.resume.title == "Resume capture")
    #expect(QuickMenuItem.openPrivacySettings.title == "Open Privacy settings…")
}

@Test(arguments: ["WhatsApp\u{200E}", "Microsoft Word", "Foo: Bar", "Notes"])
func exclusionPatternRoundTrips(name: String) {
    let pattern = QuickMenuItem.neverCaptureApp(AppName.normalize(name)).exclusionPattern!
    #expect(ExclusionRule(pattern: pattern)!.matches(ctx(app: name)))
}

@Test func sitePatternRoundTrips() {
    let c = ctx(bundleID: "com.apple.Safari", url: "https://www.github.com/x")
    let state = IndicatorState.reduce(input(front("Safari", pid: 4, bundleID: "com.apple.Safari"),
        seen(c, pid: 4, window: 1, verdict: .allowed)))
    let pattern = QuickMenuItem.neverCaptureSite(state.site!).exclusionPattern!
    #expect(pattern == "github.com")
    #expect(ExclusionRule(pattern: pattern)!.matches(ctx(bundleID: "com.apple.Safari", url: "https://www.github.com/y")))
}

@Test func appItemHiddenWhenNameNormalizesToEmpty() {
    let state = s(.capturing, "\u{200E}", pid: 1, window: 1)
    #expect(QuickMenu.items(for: state) == [.pause15, .openPrivacySettings])
}

@Test func resumeFallbackWhenPausedWithoutResumeItem() {
    #expect(QuickMenu.needsResumeFallback(isPaused: true, items: [.openPrivacySettings]))
    #expect(!QuickMenu.needsResumeFallback(isPaused: true, items: [.resume, .openPrivacySettings]))
    #expect(!QuickMenu.needsResumeFallback(isPaused: false, items: [.pause15]))
    let unknownWhilePaused = QuickMenu.items(for: .initial)
    #expect(QuickMenu.needsResumeFallback(isPaused: true, items: unknownWhilePaused))
}

@Test func statusKindNeverCarriesThePattern() {
    let k = IndicatorStatus.notCapturing(.userExcluded(pattern: "app:Secret Bank")).kind
    #expect(k == "notCapturing.userExcluded" && !k.contains("Secret"))
    #expect(IndicatorStatus.capturing.kind == "capturing")
}

@Test func siteItemHiddenForHostThatCannotBeARule() {
    let state = s(.capturing, "Safari", pid: 1, window: 1, site: "[::1]")
    #expect(QuickMenuItem.neverCaptureSite("[::1]").exclusionPattern == nil)
    #expect(QuickMenu.items(for: state) == [.neverCaptureApp("Safari"), .pause15, .openPrivacySettings])
}

@Test func subdomainOfExcludedDomainHidesSiteItem() {
    let state = s(.notCapturing(.userExcluded(pattern: "github.com")), "Safari", pid: 1, window: 1, site: "gist.github.com")
    #expect(QuickMenu.items(for: state) == [.neverCaptureApp("Safari"), .pause15, .openPrivacySettings])
}
