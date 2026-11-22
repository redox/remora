import Foundation
import Testing
@testable import Capture

// MARK: - AppName

@Test func normalizeStripsFormatCharacters() {
    #expect(AppName.normalize("\u{200E}WhatsApp") == "WhatsApp")
    #expect(AppName.normalize("What\u{200F}sApp\u{FEFF}") == "WhatsApp")
    #expect(AppName.normalize("\u{2066}WhatsApp\u{2069}") == "WhatsApp")
    #expect(AppName.normalize("\u{202A}Wh\u{202E}atsApp\u{200D}\u{200C}") == "WhatsApp")
    #expect(AppName.normalize("  Slack \n") == "Slack")
}

@Test func normalizeAppliesNFC() {
    let nfd = "Cafe\u{301}"
    #expect(AppName.normalize(nfd).unicodeScalars.count == 4)
    #expect(AppName.normalize(nfd) == "Caf\u{E9}")
}

@Test func windowContextNormalisesAppName() {
    #expect(WindowContext(app: "\u{200E}WhatsApp").app == "WhatsApp")
}

@Test(arguments: [
    ("app:WhatsApp", "\u{200E}WhatsApp", true),
    ("app:\u{200E}WhatsApp", "WhatsApp", true),
    ("app:\u{200E}WhatsApp", "\u{200F}whatsapp", true),
    ("app:Caf\u{E9}", "Cafe\u{301}", true),
    ("app:Cafe\u{301}", "CAF\u{C9}", true),
    ("app:Slack", "Slack Helper", false),
])
func appRuleIgnoresInvisibleCharsAndForm(pattern: String, app: String, expected: Bool) {
    // Build the context bypassing WindowContext.init normalisation.
    var context = ctx()
    context.app = app
    #expect(ExclusionRule(pattern: pattern)!.matches(context) == expected)
}

@Test func caseFoldingIgnoresTurkishLocale() {
    let turkish = Locale(identifier: "tr_TR")
    // Sanity: a locale-aware lowercase differs, so a localized comparison would too.
    #expect("I".lowercased(with: turkish) == "\u{131}")
    // The matcher's folding is fixed: "I" always folds to "i", never dotless.
    #expect(AppName.foldForMatching("TITLE INBOX") == "title inbox")
    #expect(ExclusionRule(pattern: "title:INBOX")!.matches(ctx(title: "my inbox")))
    #expect(ExclusionRule(pattern: "title:inbox")!.matches(ctx(title: "MY INBOX")))
    #expect(ExclusionRule(pattern: "app:IMAGE")!.matches(ctx(app: "image")))
    #expect(ExclusionRule(pattern: "url:/HR/")!.matches(ctx(url: "https://x.com/hr/a")))
    #expect(ExclusionRule(pattern: "path:PAYROLL")!.matches(ctx(path: "/u/payroll/a")))
    // Dotless i is a different letter: no Turkish-style equivalence with "I".
    #expect(!ExclusionRule(pattern: "title:\u{131}nbox")!.matches(ctx(title: "INBOX")))
}

@Test func textRulesIgnoreInvisibleCharacters() {
    #expect(ExclusionRule(pattern: "title:Secret")!.matches(ctx(title: "My \u{200F}Sec\u{200E}ret doc")))
    #expect(ExclusionRule(pattern: "title:Sec\u{200F}ret")!.matches(ctx(title: "secret")))
    #expect(ExclusionRule(pattern: "path:pay\u{200E}roll")!.matches(ctx(path: "/u/payroll/a")))
}

@Test(arguments: [
    "https://app.example.com/#/login", "https://app.example.com/#/users/forgot-password",
    "https://app.example.com/#!/signin?next=/", "https://app.example.com/app#/auth/callback",
])
func hashRoutedSignInSkipped(url: String) {
    #expect(!CapturePolicy(userRules: []).shouldCapture(ctx(url: url)))
}

@Test(arguments: [
    "https://app.example.com/#section-login", "https://app.example.com/#/blog/login-tips",
    "https://app.example.com/#login", "https://app.example.com/#/dashboard",
])
func hashFragmentsNotSignIn(url: String) {
    #expect(CapturePolicy(userRules: []).shouldCapture(ctx(url: url)))
}

@Test func safariEmptyPageTitleForm() {
    let s = SafariPrivateTitle(formats: ["%@, Private Browsing"])
    #expect(s.isPrivate(title: ", Private Browsing"))
    #expect(s.isPrivate(title: " , private browsing"))
}

@Test func safariRTLMarkInsideTitle() {
    let s = SafariPrivateTitle(formats: ["%@, Private Browsing", "\u{200F}%@، التصفح الخاص"])
    #expect(s.isPrivate(title: "\u{200F}Bank\u{200F}, Private\u{200F} Browsing"))
    #expect(s.isPrivate(title: "\u{200F}بنك، التصفح الخاص"))
}

// MARK: - Safari private titles

@Test func safariPrivateTitleFormats() {
    let s = SafariPrivateTitle(formats: [
        "%@, Private Browsing", "%@ — Navigation privée", "Privat: %@",
        "ท่องเว็บ%[tt]@", "Private Browsing",
    ])
    #expect(s.isPrivate(title: "Bank, Private Browsing"))
    #expect(s.isPrivate(title: "Bank, private browsing  "))
    #expect(s.isPrivate(title: "\u{200F}Bank, Private Browsing"))
    #expect(s.isPrivate(title: "Bank — Navigation privée"))
    #expect(s.isPrivate(title: "Privat: Bank"))
    #expect(s.isPrivate(title: "ท่องเว็บBank"))
    #expect(s.isPrivate(title: "Private Browsing"))
    #expect(!s.isPrivate(title: "Bank"))
    #expect(!s.isPrivate(title: "Private Browsing tips"))
    #expect(!s.isPrivate(title: "Why Privat: matters"))
    #expect(!s.isPrivate(title: nil))
}

@Test func safariPrivateTitleIgnoresDegenerateFormats() {
    let s = SafariPrivateTitle(formats: ["%@", "", "  "])
    #expect(!s.isPrivate(title: "anything"))
}

@Test func safariPrivateTitleEnglishFallback() {
    let s = SafariPrivateTitle(formats: [])
    #expect(s.isPrivate(title: "Example, Private Browsing"))
}

@Test(.enabled(if: FileManager.default.fileExists(atPath: "/System/Library/PrivateFrameworks/Safari.framework")))
func realSafariBundleYieldsLocalizedFormats() {
    let formats = SafariPrivateTitle.systemFormats()
    #expect(formats.contains("%@, Private Browsing"))
    #expect(formats.contains { $0.contains("navigation privée") })
    #expect(SafariPrivateTitle.system.isPrivate(title: "X, navigation privée"))
    #expect(SafariPrivateTitle.system.isPrivate(title: "X, Private Browsing"))
}

// MARK: - Built-in skips

@Test(arguments: [
    "https://a.com/login", "https://a.com/users/login/", "https://a.com/login.php",
    "https://a.com/Sign-In", "https://a.com/a/oauth/authorize?x=1", "https://a.com/sso",
    "https://a.com/saml/", "https://a.com/forgot-password", "https://a.com/2fa",
    "https://a.com/account/two-factor/verify", "https://a.com/sign_in", "https://a.com/otp.html",
    "https://a.com/reset-password", "https://a.com/recovery", "https://a.com/logon", "https://a.com/mfa",
])
func signInPathsSkipped(url: String) {
    #expect(!CapturePolicy(userRules: []).shouldCapture(ctx(url: url)))
}

@Test(arguments: [
    "https://a.com/blog/login-tips", "https://a.com/loginfo", "https://a.com/",
    "https://a.com/docs/author", "https://a.com/search?q=login",
])
func nonSignInPathsCaptured(url: String) {
    #expect(CapturePolicy(userRules: []).shouldCapture(ctx(url: url)))
}

@Test(arguments: [
    "https://my.1password.com/vaults", "https://my.1password.eu/", "https://my.1password.ca/",
    "https://vault.bitwarden.com/#/vault", "https://vault.bitwarden.eu/", "https://app.dashlane.com/",
    "https://lastpass.com/vault", "https://www.lastpass.com/", "https://keepersecurity.com/vault",
    "https://pass.proton.me/", "https://paypal.com./signin-not",
])
func vaultDomainsSkipped(url: String) {
    #expect(!CapturePolicy(userRules: []).shouldCapture(ctx(url: url)))
}

@Test func protonMailIsNotSkipped() {
    #expect(CapturePolicy(userRules: []).shouldCapture(ctx(url: "https://mail.proton.me/u/0/inbox")))
}

@Test func trailingDotHostsNormalised() {
    #expect(ctx(url: "https://paypal.com./x").domain == "paypal.com")
    #expect(!CapturePolicy(userRules: []).shouldCapture(ctx(url: "https://www.paypal.com./x")))
    #expect(ExclusionRule(pattern: "example.com.") == .domain("example.com"))
    #expect(ExclusionRule(pattern: "https://example.com./a")?.pattern == "example.com")
    #expect(ExclusionRule(pattern: "example.com.")!.matches(ctx(url: "https://example.com./a")))
}

@Test func unknownPrefixTyposRejected() {
    #expect(ExclusionRule(pattern: "tilte:secret") == nil)
    #expect(ExclusionRule(pattern: "domian:example.com") == nil)
    #expect(ExclusionRule(pattern: "example.com:abc") == nil)
    #expect(ExclusionRule(pattern: "example.com:8080") == .domain("example.com"))
    #expect(ExclusionRule(pattern: "https://example.com:8080/x") == .domain("example.com"))
    #expect(ExclusionRule(pattern: "title:a:b") == .title("a:b"))
}

@Test(arguments: [
    "com.agilebits.onepassword7", "me.proton.pass.electron", "in.sinew.Enpass-Desktop",
    "com.hicknhacksoftware.MacPass", "com.markmcguill.strongbox",
])
func morePasswordManagersSkipped(bundleID: String) {
    #expect(!CapturePolicy(userRules: []).shouldCapture(ctx(app: "PM", bundleID: bundleID)))
}

@Test(arguments: ["https://www.example.bank/login-free", "https://online.example.bank/", "https://example.bank./x"])
func bankTLDSkipped(url: String) {
    #expect(!CapturePolicy(userRules: []).shouldCapture(ctx(url: url)))
}

@Test func bankWordElsewhereNotSkipped() {
    #expect(CapturePolicy(userRules: []).shouldCapture(ctx(url: "https://bank.example.com/blog")))
    #expect(CapturePolicy(userRules: []).shouldCapture(ctx(url: "https://examplebank.com/")))
}
