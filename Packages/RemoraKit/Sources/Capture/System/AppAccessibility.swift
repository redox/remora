import AppKit
import ApplicationServices
import Synchronization

/// Chromium and Electron build their accessibility tree only for assistive tech they recognise.
/// Electron apps (bundle embeds Electron Framework) get `AXManualAccessibility`; Chromium browsers
/// also get `AXEnhancedUserInterface`. Once per process launch, shared by capture's window reader
/// and the rewrite key's field reader (so the first tap in a fresh Electron app works even while
/// capture is paused). Built-in skipped apps (e.g. 1Password 8, an Electron app) are never walked,
/// so their flags are left alone.
public enum AppAccessibility {
    static let launches = Launches()

    /// Sets the flags `app` needs, once per launch. AX queue only.
    public static func enable(_ app: NSRunningApplication, session: AXReadSession) {
        enable(pid: app.processIdentifier, bundleID: app.bundleIdentifier, bundleURL: app.bundleURL,
               launchDate: app.launchDate, session: session)
    }

    /// AX queue only.
    static func enable(pid: pid_t, bundleID: String?, bundleURL: URL?, launchDate: Date?, session: AXReadSession) {
        if let bundleID, BuiltInSkipList.bundleIDs.contains(bundleID) { return }
        let element = AXUIElementCreateApplication(pid)
        AXReadSession.bound(element)
        enable(key: "\(pid)-\(launchDate?.timeIntervalSince1970 ?? 0)", launches: launches,
               flags: { flags(bundleID: bundleID, isElectron: AppKind.isElectron(bundleURL: bundleURL)) },
               set: { session.setFlag(element, $0) }, unresponsive: { session.isUnresponsive })
    }

    /// The flags an app needs; none for a built-in skipped app.
    static func flags(bundleID: String?, isElectron: Bool) -> [String] {
        if let bundleID, BuiltInSkipList.bundleIDs.contains(bundleID) { return [] }
        let chromium = BrowserCatalog.isChromiumBrowser(bundleID)
        var out: [String] = []
        if chromium || isElectron { out.append("AXManualAccessibility") }
        if chromium { out.append("AXEnhancedUserInterface") }
        return out
    }

    /// Sets `flags` once per `key`; a launch too busy to take them is retried on a later call.
    static func enable(key: String, launches: Launches, flags: () -> [String], set: (String) -> Void,
                       unresponsive: () -> Bool) {
        guard launches.insert(key) else { return }
        flags().forEach(set)
        if unresponsive() { launches.remove(key) }
    }

    /// Process launches (pid + launch date) whose flags were already handled.
    final class Launches: Sendable {
        private let keys = Mutex<Set<String>>([])
        /// True if the key was newly inserted.
        func insert(_ key: String) -> Bool { keys.withLock { $0.insert(key).inserted } }
        func remove(_ key: String) { _ = keys.withLock { $0.remove(key) } }
    }
}
