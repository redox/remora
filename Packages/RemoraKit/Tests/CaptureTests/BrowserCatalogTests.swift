import Testing
@testable import Capture

@Test func knownBrowsers() {
    for id in ["com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser",
               "com.microsoft.edgemac", "com.brave.Browser", "org.mozilla.firefox"] {
        #expect(BrowserCatalog.isBrowser(id))
    }
    #expect(!BrowserCatalog.isBrowser("com.apple.Notes"))
    #expect(!BrowserCatalog.isBrowser(nil))
}

@Test func chromiumBrowsersNeedEnhancedUI() {
    #expect(BrowserCatalog.isChromiumBrowser("com.google.Chrome"))
    #expect(BrowserCatalog.isChromiumBrowser("company.thebrowser.Browser"))
    #expect(BrowserCatalog.isChromiumBrowser("com.microsoft.edgemac"))
    #expect(BrowserCatalog.isChromiumBrowser("com.brave.Browser"))
    #expect(!BrowserCatalog.isChromiumBrowser("com.apple.Safari"))
    #expect(!BrowserCatalog.isChromiumBrowser("org.mozilla.firefox"))
}

@Test(arguments: [
    ("org.mozilla.firefox", "Bank — Private Browsing", [String](), true),
    ("org.mozilla.firefox", "Bank — Mozilla Firefox", [], false),
    ("com.google.Chrome", "Bank", ["Incognito"], true),
    ("com.google.Chrome", "Bank", ["Incognito (2)"], true),
    ("com.google.Chrome", "Bank", ["Profile: Ana", "Reload"], false),
    ("com.google.Chrome", "Bank (Incognito)", [], true),
    ("com.microsoft.edgemac", "Bank", ["InPrivate"], true),
    ("com.brave.Browser", "Bank", ["Private"], true),
    ("com.apple.Safari", "Bank", ["Private Browsing"], true),
    ("com.apple.Safari", "Private Browsing tips and tricks", [], false),
    ("com.google.Chrome", "Incognito mode explained", ["Incognito mode explained"], false),
    ("com.apple.Notes", "Bank — Private Browsing", ["Incognito"], false),
])
func privateBrowsingHeuristics(bundleID: String, title: String, labels: [String], expected: Bool) {
    #expect(BrowserCatalog.looksPrivate(bundleID: bundleID, windowTitle: title,
                                        chromeLabels: labels) == expected)
}

// MARK: - Families (final review #7)

@Test(arguments: [
    ("com.google.Chrome.beta", BrowserCatalog.Family.chromium),
    ("com.google.Chrome.dev", .chromium), ("com.google.Chrome.canary", .chromium),
    ("org.chromium.Chromium", .chromium), ("com.vivaldi.Vivaldi", .chromium),
    ("com.operasoftware.Opera", .chromium), ("company.thebrowser.dia", .chromium),
    ("company.thebrowser.Browser", .chromium), ("com.microsoft.edgemac", .chromium),
    ("com.brave.Browser", .chromium), ("com.google.Chrome", .chromium),
    ("org.mozilla.firefox", .gecko), ("org.mozilla.firefoxdeveloperedition", .gecko),
    ("org.mozilla.nightly", .gecko), ("app.zen-browser.zen", .gecko),
    ("com.apple.Safari", .webkit), ("com.apple.SafariTechnologyPreview", .webkit),
    ("com.kagi.kagimacOS", .webkit), ("com.duckduckgo.macos.browser", .webkit),
])
func browserFamilies(bundleID: String, family: BrowserCatalog.Family) {
    #expect(BrowserCatalog.family(of: bundleID) == family)
    #expect(BrowserCatalog.isBrowser(bundleID))
    #expect(BrowserCatalog.isChromiumBrowser(bundleID) == (family == .chromium))
}

@Test func safariFamilyUsesSafariPrivateTitle() {
    #expect(BrowserCatalog.usesSafariPrivateTitle("com.apple.Safari"))
    #expect(BrowserCatalog.usesSafariPrivateTitle("com.apple.SafariTechnologyPreview"))
    #expect(!BrowserCatalog.usesSafariPrivateTitle("com.kagi.kagimacOS"))
    #expect(!BrowserCatalog.usesSafariPrivateTitle("com.google.Chrome"))
}

@Test(arguments: [
    // Chromium family, localized "(Incognito)"-style suffixes.
    ("com.google.Chrome", "Banque (Navigation privée)"), ("com.google.Chrome", "Bank (Inkognito)"),
    ("com.google.Chrome.canary", "Banco (Incógnito)"), ("com.vivaldi.Vivaldi", "Banca (In incognito)"),
    ("com.google.Chrome", "Banco (Anônima)"), ("com.google.Chrome", "Banco (Anónimo)"),
    ("org.chromium.Chromium", "Bank (Incognito)"), ("com.google.Chrome", "Bank - Google Chrome (Incognito)"),
    ("com.google.Chrome", "Bank (INCOGNITO)  "), ("com.microsoft.edgemac", "Bank [InPrivate]"),
    ("com.brave.Browser", "Bank (Private)"),
    // Gecko family, localized "— Private Browsing"-style suffixes.
    ("org.mozilla.firefox", "Banque — Navigation privée"), ("org.mozilla.firefox", "Bank — Privater Modus"),
    ("org.mozilla.firefoxdeveloperedition", "Banco — Navegación privada"),
    ("org.mozilla.nightly", "Banca — Navigazione anonima"), ("app.zen-browser.zen", "Banco — Navegação privada"),
    ("org.mozilla.firefox", "Bank — Privénavigatie"), ("org.mozilla.firefox", "Bank - Private Browsing"),
    ("org.mozilla.firefox", "Bank — Mozilla Firefox Private Browsing"),
])
func localizedPrivateTitles(bundleID: String, title: String) {
    #expect(BrowserCatalog.looksPrivate(bundleID: bundleID, windowTitle: title, chromeLabels: []))
}

@Test(arguments: [
    ("com.google.Chrome", "Incognito mode explained"),
    ("com.google.Chrome", "Navigation privée : le guide complet"),
    ("com.google.Chrome", "How to go incognito"),
    ("org.mozilla.firefox", "Privater Modus erklärt — Wiki"),
    ("org.mozilla.firefox", "Navegación privada en Firefox — Mozilla Firefox"),
    ("org.mozilla.firefox", "Bank — Mozilla Firefox"),
    ("com.google.Chrome", "Inkognito (Film) review"),
    ("com.apple.Notes", "Bank (Incognito)"),
])
func titlesMerelyContainingMarkersAreNotPrivate(bundleID: String, title: String) {
    #expect(!BrowserCatalog.looksPrivate(bundleID: bundleID, windowTitle: title, chromeLabels: []))
}

// MARK: - Browsers fail closed without a URL

@Test func browserWithoutURLIsNotCaptured() {
    let policy = CapturePolicy(userRules: [])
    #expect(!policy.shouldCapture(ctx(app: "Chrome", bundleID: "com.google.Chrome", title: "x")))
    #expect(!policy.shouldCapture(ctx(app: "Zen", bundleID: "app.zen-browser.zen", title: "x")))
    #expect(policy.shouldCapture(ctx(app: "Chrome", bundleID: "com.google.Chrome", title: "x",
                                     url: "https://example.com/")))
    // Non-browsers without a URL are unaffected.
    #expect(policy.shouldCapture(ctx(app: "Notes", bundleID: "com.apple.Notes", title: "x")))
}
