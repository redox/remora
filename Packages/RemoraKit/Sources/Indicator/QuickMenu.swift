import Capture

public enum QuickMenuItem: Sendable, Hashable {
    case neverCaptureApp(String), neverCaptureSite(String), pause15, resume, openPrivacySettings

    public var title: String {
        switch self {
        case .neverCaptureApp: "Never capture this app"
        case .neverCaptureSite: "Never capture this site"
        case .pause15: "Pause 15 min"
        case .resume: "Resume capture"
        case .openPrivacySettings: "Open Privacy settings…"
        }
    }

    /// The exclusion rule pattern this item writes, if any.
    public var exclusionPattern: String? {
        switch self {
        case .neverCaptureApp(let name): ExclusionRule.app(AppName.normalize(name)).pattern
        case .neverCaptureSite(let host): ExclusionRule(pattern: host)?.pattern
        default: nil
        }
    }
}

public enum QuickMenu {
    /// True when capture is paused but the quick items offer no Resume (Remora frontmost,
    /// no Accessibility, unreadable pause value), so the menu must add its own.
    public static func needsResumeFallback(isPaused: Bool, items: [QuickMenuItem]) -> Bool {
        isPaused && !items.contains(.resume)
    }

    public static func items(for s: IndicatorState) -> [QuickMenuItem] {
        switch s.status {
        case .noAccessibility: return [.openPrivacySettings]
        case .unknown, .pending: return [.pause15, .openPrivacySettings]
        case .paused:
            return (appItem(s).map { [$0] } ?? []) + [.resume, .openPrivacySettings]
        case .capturing, .notCapturing:
            var out: [QuickMenuItem] = []
            if let a = appItem(s) { out.append(a) }
            if let site = siteItem(s) { out.append(site) }
            return out + [.pause15, .openPrivacySettings]
        }
    }

    private static func appItem(_ s: IndicatorState) -> QuickMenuItem? {
        guard let name = s.appName, !AppName.normalize(name).isEmpty else { return nil }
        if case .notCapturing(let v) = s.status {
            if v == .passwordManager { return nil }
            if case .userExcluded(let p) = v, case .app? = ExclusionRule(pattern: p) { return nil }
        }
        return .neverCaptureApp(name)
    }

    private static func siteItem(_ s: IndicatorState) -> QuickMenuItem? {
        guard let site = s.site else { return nil }
        if case .notCapturing(let v) = s.status {
            if v == .sensitiveSite { return nil }
            if case .userExcluded(let p) = v, case .domain(let d)? = ExclusionRule(pattern: p),
               ExclusionRule.host(site, matchesDomain: d) { return nil }
        }
        // A host that cannot be written as a rule (IPv6 literal, odd characters) gets no item.
        let item = QuickMenuItem.neverCaptureSite(site)
        return item.exclusionPattern == nil ? nil : item
    }
}
