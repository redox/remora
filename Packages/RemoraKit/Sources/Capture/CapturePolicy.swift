public struct CapturePolicy: Sendable {
    private let userRules: [ExclusionRule]
    private let denyEverything: Bool

    public init(userRules: [ExclusionRule]) { self.init(userRules: userRules, denyEverything: false) }

    private init(userRules: [ExclusionRule], denyEverything: Bool) {
        self.userRules = userRules
        self.denyEverything = denyEverything
    }

    /// Captures nothing: used when the user's exclusions cannot be loaded (fail closed), so
    /// the reader still returns the context (for app-only focus) without walking any text.
    public static let denyAll = CapturePolicy(userRules: [], denyEverything: true)

    /// True for `.denyAll` (the exclusions could not be loaded): callers that would otherwise
    /// keep rows citing no snapshot, or only deleted ones, show nothing instead (fail closed).
    public var deniesEverything: Bool { denyEverything }

    public func shouldCapture(_ ctx: WindowContext) -> Bool { verdict(ctx) == .allowed }

    /// The app-level part of the verdict, for a context with no window information yet (a browser
    /// whose URL is not read): rules unavailable, password-manager bundle, `app:` user rules.
    /// Skips every URL/domain/sign-in/unknown-URL check; anything else is `.allowed`.
    public func appVerdict(_ ctx: WindowContext) -> CaptureVerdict {
        if denyEverything { return .rulesUnavailable }
        if let id = ctx.bundleID, BuiltInSkipList.bundleIDs.contains(id) { return .passwordManager }
        for rule in userRules {
            guard case .app = rule, rule.matches(ctx) else { continue }
            return .userExcluded(pattern: rule.pattern)
        }
        return .allowed
    }

    /// Why a context is (not) captured. Checks run in a fixed order; the first hit wins.
    public func verdict(_ ctx: WindowContext) -> CaptureVerdict {
        if denyEverything { return .rulesUnavailable }
        if ctx.isPrivateBrowsing { return .privateWindow }
        // A browser whose page URL is unknown cannot be checked against domain/sign-in/user
        // URL rules (and may be a private window hiding it): fail closed.
        if BrowserCatalog.isBrowser(ctx.bundleID), ctx.url == nil { return .unknownURL }
        if let id = ctx.bundleID, BuiltInSkipList.bundleIDs.contains(id) { return .passwordManager }
        if let host = ctx.domain,
           BuiltInSkipList.domains.contains(where: { ExclusionRule.host(host, matchesDomain: $0) }) {
            return .sensitiveSite
        }
        if BuiltInSkipList.isSignInURL(ctx.url) { return .signInPage }
        if let rule = userRules.first(where: { $0.matches(ctx) }) { return .userExcluded(pattern: rule.pattern) }
        return .allowed
    }
}

/// The reason a window is or is not captured. Carries a rule pattern, never window content.
public enum CaptureVerdict: Sendable, Hashable {
    case allowed, rulesUnavailable, privateWindow, unknownURL, passwordManager, sensitiveSite, signInPage
    case userExcluded(pattern: String)
}
