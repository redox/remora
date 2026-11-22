import Foundation

/// Static knowledge about browsers: which bundle ids get web-area extraction, their engine
/// family (for AX flags and private-window markers), and best-effort private-window heuristics.
///
/// Any known browser fails closed: if no URL can be determined for the captured web area, no
/// text is captured and focus is recorded app-only (see `CapturePolicy`).
///
/// Private-browsing detectability. None of these browsers exposes a documented AX flag, so
/// everything below is BEST EFFORT and must be confirmed by the manual capture matrix:
/// - Chromium family (Chrome and its channels, Chromium, Arc, Dia, Edge, Brave, Vivaldi, Opera):
///   incognito windows show an "Incognito" avatar button in the toolbar ("Incognito (N)" with
///   several windows); the window title may end with a parenthesised marker such as
///   "(Incognito)", FR "(Navigation privée)", DE "(Inkognito)", ES "(Incógnito)",
///   IT "(In incognito)", PT "(Anônima)"/"(Anónimo)", NL "(Incognito)"; Edge "[InPrivate]";
///   Brave "(Private)". The exact localized wording is not verified for every language, so a
///   trailing parenthesised/bracketed group containing a distinctive word is matched,
///   anchored at the END of the title only.
/// - Gecko family (Firefox, Developer Edition, Nightly, Zen): a private window's title ends
///   with "— Private Browsing" in the UI language: FR "— Navigation privée", DE "— Privater
///   Modus", ES "— Navegación privada", IT "— Navigazione anonima", PT "— Navegação privada",
///   NL "— Privénavigatie". The last dash-separated segment is matched, anchored at the end.
/// - WebKit family: Safari and Safari Technology Preview title private windows with Safari's
///   own localized format ("<page>, Private Browsing"); `SafariPrivateTitle` matches every
///   localization of the installed Safari and the reader applies it. Orion and DuckDuckGo
///   formats are unknown, so they get both the Chromium and the Gecko title markers.
/// - Every family: exact chrome labels ("Incognito", "InPrivate", "Private", ...).
///
/// Matching folds case and diacritics. False positives only suppress capture (fail safe);
/// false negatives capture private content.
public enum BrowserCatalog {
    public enum Family: Sendable, Equatable { case chromium, gecko, webkit }

    public static let safari = "com.apple.Safari"
    public static let safariTechnologyPreview = "com.apple.SafariTechnologyPreview"
    public static let firefox = "org.mozilla.firefox"

    public static let families: [String: Family] = [
        // Chromium: get `AXEnhancedUserInterface` + `AXManualAccessibility`.
        "com.google.Chrome": .chromium,
        "com.google.Chrome.beta": .chromium,
        "com.google.Chrome.dev": .chromium,
        "com.google.Chrome.canary": .chromium,
        "org.chromium.Chromium": .chromium,
        "company.thebrowser.Browser": .chromium,  // Arc
        "company.thebrowser.dia": .chromium,  // Dia
        "com.microsoft.edgemac": .chromium,
        "com.microsoft.edgemac.Beta": .chromium,
        "com.microsoft.edgemac.Dev": .chromium,
        "com.microsoft.edgemac.Canary": .chromium,
        "com.brave.Browser": .chromium,
        "com.brave.Browser.beta": .chromium,
        "com.brave.Browser.nightly": .chromium,
        "com.vivaldi.Vivaldi": .chromium,
        "com.operasoftware.Opera": .chromium,
        // Gecko.
        "org.mozilla.firefox": .gecko,
        "org.mozilla.firefoxdeveloperedition": .gecko,
        "org.mozilla.nightly": .gecko,
        "app.zen-browser.zen": .gecko,
        // WebKit.
        "com.apple.Safari": .webkit,
        "com.apple.SafariTechnologyPreview": .webkit,
        "com.kagi.kagimacOS": .webkit,  // Orion
        "com.duckduckgo.macos.browser": .webkit,
    ]

    public static var browsers: Set<String> { Set(families.keys) }
    public static var chromiumBrowsers: Set<String> { Set(families.filter { $0.value == .chromium }.keys) }

    public static func family(of bundleID: String?) -> Family? {
        bundleID.flatMap { families[$0] }
    }

    public static func isBrowser(_ bundleID: String?) -> Bool { family(of: bundleID) != nil }

    public static func isChromiumBrowser(_ bundleID: String?) -> Bool { family(of: bundleID) == .chromium }

    /// Safari and Safari Technology Preview share Safari's localized private-window title.
    public static func usesSafariPrivateTitle(_ bundleID: String?) -> Bool {
        bundleID == safari || bundleID == safariTechnologyPreview
    }

    /// Distinctive words of a Chromium-style trailing "(…)"/"[…]" marker (folded).
    static let chromiumMarkerWords = [
        "incognito", "inkognito", "incognita", "inprivate", "private", "privat", "privee",
        "privada", "privado", "anonima", "anonimo", "anonym",
    ]

    /// Distinctive phrases of a Gecko-style trailing "— …" segment (folded).
    static let geckoMarkerPhrases = [
        "private browsing", "navigation privee", "privater modus", "navegacion privada",
        "navigazione anonima", "navegacao privada", "privenavigatie",
    ]

    /// Exact (folded) labels of toolbar/chrome elements that only appear in private windows.
    /// Exact matching keeps page titles like "Incognito mode explained" out.
    static let privateChromeLabels: Set<String> = [
        "incognito", "inprivate", "private", "private browsing", "private window",
    ]

    /// Best-effort private-window guess from the window title and the labels (title or
    /// description) of chrome elements outside the web area.
    public static func looksPrivate(bundleID: String?, windowTitle: String?,
                                    chromeLabels: [String]) -> Bool {
        guard let family = family(of: bundleID) else { return false }
        if let windowTitle {
            let title = fold(windowTitle)
            let otherWebKit = family == .webkit && !usesSafariPrivateTitle(bundleID)
            if family == .chromium || otherWebKit, hasChromiumMarker(title) { return true }
            if family == .gecko || otherWebKit, hasGeckoMarker(title) { return true }
        }
        return chromeLabels.contains(where: isPrivateLabel)
    }

    /// The title ends with "(…)" or "[…]" (≤ 40 chars inside) containing a marker word.
    static func hasChromiumMarker(_ title: String) -> Bool {
        guard let match = title.firstMatch(of: /[(\[]([^()\[\]]{1,40})[)\]]$/) else { return false }
        let words = match.1.split(whereSeparator: { !$0.isLetter })
        return words.contains { chromiumMarkerWords.contains(String($0)) }
    }

    /// The title's last "—"/"–"/" - " segment (≤ 60 chars) ends with a marker phrase.
    static func hasGeckoMarker(_ title: String) -> Bool {
        guard let match = title.firstMatch(of: /(?:—|–| - )\s*([^—–]{1,60})$/) else { return false }
        let segment = String(match.1).trimmingCharacters(in: .whitespaces)
        return geckoMarkerPhrases.contains { segment.hasSuffix($0) }
    }

    static func isPrivateLabel(_ raw: String) -> Bool {
        let label = fold(raw)
        if privateChromeLabels.contains(label) { return true }
        // Chrome numbers its incognito avatar with several windows open: "Incognito (2)".
        return label.wholeMatch(of: /incognito \(\d+\)/) != nil
    }

    /// Format characters removed, trimmed, case- and diacritic-folded (POSIX).
    static func fold(_ s: String) -> String {
        AppName.normalize(s).folding(options: [.caseInsensitive, .diacriticInsensitive],
                                     locale: Locale(identifier: "en_US_POSIX"))
    }
}
