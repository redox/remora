import Foundation
import Testing
@testable import Capture

func ctx(
    app: String = "Safari",
    bundleID: String? = nil,
    title: String? = nil,
    url: String? = nil,
    path: String? = nil,
    privateBrowsing: Bool = false
) -> WindowContext {
    WindowContext(
        app: app, bundleID: bundleID, windowTitle: title,
        url: url.flatMap { URL(string: $0) }, filePath: path,
        isPrivateBrowsing: privateBrowsing)
}

@Test(arguments: [
    ("intranet.example.com", ctx(url: "https://hr.intranet.example.com/x"), true),
    ("intranet.example.com", ctx(url: "https://notintranet.example.com.evil.io"), false),
    ("app:Slack", ctx(app: "slack"), true),
    ("title:Confidential", ctx(title: "Q3 — CONFIDENTIAL draft"), true),
    ("url:/hr/", ctx(url: "https://corp.com/HR/payroll"), true),
    ("path:payroll", ctx(path: "/Users/me/Payroll/2026.xlsx"), true),
    ("APP:Slack", ctx(app: "Slack"), true),
    ("https://intranet.example.com/x", ctx(url: "https://intranet.example.com/y"), true),
    ("*.example.com", ctx(url: "https://a.example.com"), true),
    ("intranet.example.com", ctx(), false),
])
func ruleMatching(pattern: String, context: WindowContext, expected: Bool) {
    #expect(ExclusionRule(pattern: pattern)!.matches(context) == expected)
}

@Test func malformedRulesRejected() {
    #expect(ExclusionRule(pattern: "app:") == nil)
    #expect(ExclusionRule(pattern: "  ") == nil)
    #expect(ExclusionRule(pattern: "title:   ") == nil)
    #expect(ExclusionRule(pattern: "https://") == nil)
}

@Test func patternRoundTrips() {
    #expect(ExclusionRule(pattern: " App:Slack ")?.pattern == "app:Slack")
    #expect(ExclusionRule(pattern: "https://Intranet.Example.com/x")?.pattern == "intranet.example.com")
    #expect(ExclusionRule(pattern: "*.example.com") == .domain("example.com"))
}

@Test func policySkipsPrivatePasswordManagersAndBanks() {
    let p = CapturePolicy(userRules: [])
    #expect(!p.shouldCapture(ctx(app: "Safari", url: "https://x.com", privateBrowsing: true)))
    #expect(!p.shouldCapture(ctx(app: "1Password", bundleID: "com.1password.1password")))
    #expect(!p.shouldCapture(ctx(app: "Safari", url: "https://clients.boursorama.com/compte")))
    #expect(p.shouldCapture(ctx(app: "Safari", url: "https://news.ycombinator.com")))
}

@Test func policyAppliesUserRules() {
    let p = CapturePolicy(userRules: [ExclusionRule(pattern: "app:Slack")!])
    #expect(!p.shouldCapture(ctx(app: "Slack")))
    #expect(p.shouldCapture(ctx(app: "Mail")))
}

@Test func verdictReasons() {
    let p = CapturePolicy(userRules: [ExclusionRule(pattern: "app:Slack")!])
    let safari = "com.apple.Safari"
    #expect(p.verdict(ctx(bundleID: safari, url: "https://x.com", privateBrowsing: true)) == .privateWindow)
    #expect(p.verdict(ctx(bundleID: safari)) == .unknownURL)
    #expect(p.verdict(ctx(app: "1Password", bundleID: "com.1password.1password")) == .passwordManager)
    #expect(p.verdict(ctx(bundleID: safari, url: "https://clients.boursorama.com/")) == .sensitiveSite)
    #expect(p.verdict(ctx(bundleID: safari, url: "https://github.com/login")) == .signInPage)
    #expect(p.verdict(ctx(app: "Slack")) == .userExcluded(pattern: "app:Slack"))
    #expect(p.verdict(ctx(app: "Notes")) == .allowed)
    #expect(CapturePolicy.denyAll.verdict(ctx(app: "Notes")) == .rulesUnavailable)
}

@Test func appVerdictIgnoresUrlChecksAndHonorsAppLevelRules() {
    let safari = "com.apple.Safari"
    let p = CapturePolicy(userRules: [.app("Safari"), .domain("example.com")])
    #expect(p.appVerdict(ctx(app: "Safari", bundleID: safari)) == .userExcluded(pattern: "app:Safari"))
    #expect(p.appVerdict(ctx(app: "1Password", bundleID: "com.1password.1password")) == .passwordManager)
    #expect(CapturePolicy.denyAll.appVerdict(ctx(app: "Notes")) == .rulesUnavailable)
    // A browser without URL, domain rules and title rules do not apply at app level.
    let q = CapturePolicy(userRules: [.domain("example.com"), .title("secret")])
    #expect(q.appVerdict(ctx(app: "Safari", bundleID: safari)) == .allowed)
    #expect(q.verdict(ctx(app: "Safari", bundleID: safari)) == .unknownURL)
}
