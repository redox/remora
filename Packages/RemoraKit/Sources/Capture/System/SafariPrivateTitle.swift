import AppKit

/// Recognises Safari private-window titles. Safari titles them with its own localized format
/// `"%@, Private Browsing"` (a key in the `Localizable.strings` of every localization of
/// Apple's Safari resources), so this loads that format from the installed system in every
/// available language. Pure matching is separate from loading, for tests.
public struct SafariPrivateTitle: Sendable {
    private struct Matcher: Sendable {
        var prefix: String
        var suffix: String
        var hasPlaceholder: Bool

        func matches(_ title: String) -> Bool {
            if !hasPlaceholder { return title == prefix }
            return title.count >= prefix.count + suffix.count
                && title.hasPrefix(prefix) && title.hasSuffix(suffix)
        }
    }

    static let titleKey = "%@, Private Browsing"
    /// Title of a private window that has no page title yet.
    static let bareKey = "Private Browsing (window title)"
    static let englishFormats = ["%@, Private Browsing", "Private Browsing"]

    private let matchers: [Matcher]

    /// `formats` use `%@` (or `%[...]@`) for the page title. Without a placeholder the format
    /// must equal the whole title. An empty list falls back to the English formats.
    public init(formats: [String]) {
        let source = formats.isEmpty ? Self.englishFormats : formats
        matchers = source.compactMap(Self.makeMatcher)
    }

    public func isPrivate(title: String?) -> Bool {
        guard let title else { return false }
        let t = AppName.fold(AppName.stripFormatting(title)
            .trimmingCharacters(in: .whitespacesAndNewlines))
        return matchers.contains { $0.matches(t) }
    }

    private static func makeMatcher(_ raw: String) -> Matcher? {
        let format = AppName.fold(AppName.stripFormatting(raw))
        guard !format.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let range = format.firstMatch(of: /%(?:\[[^\]]*\])?@/)?.range else {
            return Matcher(prefix: format.trimmingCharacters(in: .whitespacesAndNewlines),
                           suffix: "", hasPlaceholder: false)
        }
        let prefix = String(format[..<range.lowerBound])
        let suffix = String(format[range.upperBound...])
        // Both affixes are trimmed at the title's edge, never inside it.
        guard !(prefix.isEmpty && suffix.isEmpty) else { return nil }
        return Matcher(prefix: prefix, suffix: suffix, hasPlaceholder: true)
    }

    // MARK: - System formats

    /// Loads the system formats now. Call once at launch off the main thread so the first
    /// Safari capture never pays for ~44 synchronous plist reads.
    public static func prewarm() { _ = system }

    /// Formats of the installed Safari, loaded once.
    public static let system = SafariPrivateTitle(formats: systemFormats())

    /// Reads the format key from every `*.lproj/Localizable.strings` of the installed Safari
    /// app and of its own `Safari.framework` (where Apple ships those strings; the app
    /// bundle's resources hold only per-view tables). Always includes the English formats.
    static func systemFormats() -> [String] {
        var found = Set(englishFormats)
        for resources in resourceDirectories() {
            // Path-based listing: the framework's `Resources` is a symlink, which a
            // URL-based listing refuses to open.
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: resources.path)
            else { continue }
            for lproj in entries where lproj.hasSuffix(".lproj") {
                let table = resources.appending(path: lproj).appending(path: "Localizable.strings")
                guard let dict = NSDictionary(contentsOf: table) as? [String: String] else { continue }
                for key in [titleKey, bareKey] {
                    if let value = dict[key], !value.isEmpty { found.insert(value) }
                }
            }
        }
        return found.sorted()
    }

    private static func resourceDirectories() -> [URL] {
        var urls: [URL] = []
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: BrowserCatalog.safari) {
            urls.append(app.appending(path: "Contents/Resources"))
            urls.append(app.appending(path: "Contents/Frameworks/Safari.framework/Resources"))
        }
        urls.append(URL(filePath: "/System/Library/PrivateFrameworks/Safari.framework/Resources"))
        return urls.filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }
}
