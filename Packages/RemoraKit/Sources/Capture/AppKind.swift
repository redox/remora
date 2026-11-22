import Foundation

/// What kind of app a bundle is, for decisions that depend on how it renders text.
public enum AppKind {
    /// A browser, or an app built on Electron. Their text views are web content: AX writes are
    /// often reported as successful without taking effect, so text goes in by pasting instead.
    public static func isWebBacked(bundleID: String?, bundleURL: URL?) -> Bool {
        BrowserCatalog.isBrowser(bundleID) || isElectron(bundleURL: bundleURL)
    }

    /// The bundle embeds `Contents/Frameworks/Electron Framework.framework`.
    public static func isElectron(bundleURL: URL?) -> Bool {
        guard let bundleURL else { return false }
        return FileManager.default.fileExists(atPath: bundleURL.appending(
            path: "Contents/Frameworks/Electron Framework.framework").path(percentEncoded: false))
    }
}
