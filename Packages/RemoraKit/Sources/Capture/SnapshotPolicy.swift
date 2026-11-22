import Foundation
import Storage

/// Applies the user's exclusions as they stand **now** to rows captured earlier, so excluding an
/// app or site also keeps its old snapshots (and its focus time) out of every prompt (F-37b,
/// F-55, F-58).
public enum SnapshotPolicy {
    /// The policy from freshly loaded exclusions; `.denyAll` when they cannot be loaded (fail closed).
    public static func current(_ db: AppDatabase) -> CapturePolicy {
        do { return CapturePolicy(userRules: try ExclusionStore(db).all().compactMap(ExclusionRule.init(pattern:))) } catch {
            return .denyAll
        }
    }

    /// Whether `policy` would capture the window this snapshot came from. The stored URL is the
    /// redacted string and may not parse to a host, so the stored domain is also checked as
    /// `https://<domain>`: the snapshot is allowed only when every available reading is (a URL
    /// rule still sees the full stored URL; a domain rule always sees the real host). A browser
    /// snapshot with neither cannot be checked and is denied.
    public static func allows(_ s: Snapshot, policy: CapturePolicy) -> Bool {
        var urls: [URL] = []
        if let raw = s.url, let url = URL(string: raw), url.host() != nil { urls.append(url) }
        if let domain = s.domain, !domain.isEmpty, let url = URL(string: "https://\(domain)"),
           url.host() != nil, !urls.contains(where: { $0.host()?.lowercased() == domain.lowercased() }) {
            urls.append(url)
        }
        func context(_ url: URL?) -> WindowContext {
            WindowContext(app: s.app, bundleID: s.bundleID, windowTitle: s.windowTitle, url: url, filePath: s.filePath)
        }
        guard !urls.isEmpty else { return policy.shouldCapture(context(nil)) }
        return urls.allSatisfy { policy.shouldCapture(context($0)) }
    }

    /// Whether a focus event may be shown under `policy`. Events of excluded windows were stored
    /// by app name only (no title or domain), and a browser event without a domain cannot be
    /// checked against site rules, so those are judged at the app level (`appVerdict`): the app
    /// name of an excluded app never passes.
    public static func allows(_ e: ActivityEvent, policy: CapturePolicy) -> Bool {
        let url = e.domain.flatMap { $0.isEmpty ? nil : URL(string: "https://\($0)") }
        let ctx = WindowContext(app: e.app, bundleID: e.bundleID, windowTitle: e.windowTitle, url: url)
        if url == nil, BrowserCatalog.isBrowser(e.bundleID) { return policy.appVerdict(ctx) == .allowed }
        return policy.shouldCapture(ctx)
    }

    /// Whether time recorded under an app name and an optional domain only (a time-ledger row:
    /// no bundle id, no title) may be shown under `policy`: with a domain, the full check on
    /// `https://<domain>`; without one, the app-level verdict, as for a name-only focus event.
    public static func allows(app: String, domain: String?, policy: CapturePolicy) -> Bool {
        let url = domain.flatMap { $0.isEmpty ? nil : URL(string: "https://\($0)") }
        let ctx = WindowContext(app: app, bundleID: nil, windowTitle: nil, url: url)
        return url == nil ? policy.appVerdict(ctx) == .allowed : policy.shouldCapture(ctx)
    }

    /// Whether an inline output may be shown under `policy`. Its surface is the page's domain in
    /// a browser (otherwise the bundle id or app name), so in a browser the surface is checked as
    /// the site; a browser output with no domain is judged at the app level.
    public static func allows(_ o: InlineOutput, policy: CapturePolicy) -> Bool {
        let isBrowser = BrowserCatalog.isBrowser(o.bundleID)
        let domain = isBrowser && o.surface != o.bundleID && o.surface != o.app ? o.surface : nil
        let url = domain.flatMap { URL(string: "https://\($0)") }.flatMap { $0.host() == nil ? nil : $0 }
        let ctx = WindowContext(app: o.app, bundleID: o.bundleID, windowTitle: nil, url: url)
        if isBrowser, url == nil { return policy.appVerdict(ctx) == .allowed }
        return policy.shouldCapture(ctx)
    }
}
