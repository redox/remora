import Capture
import Foundation

/// The frontmost application as known from the workspace (no AX). `appVerdict` is the verdict
/// of an app-only context, nil until known.
public struct FrontmostApp: Sendable, Equatable {
    public var pid: Int32
    public var name: String
    public var bundleID: String?
    public var appVerdict: CaptureVerdict?

    public init(pid: Int32, name: String, bundleID: String? = nil, appVerdict: CaptureVerdict? = nil) {
        self.pid = pid
        self.name = name
        self.bundleID = bundleID
        self.appVerdict = appVerdict
    }
}

/// A context sample together with the verdict it earned.
public struct ObservedWindow: Sendable, Equatable {
    public var context: WindowContext
    public var identity: ContextIdentity
    public var verdict: CaptureVerdict

    public init(context: WindowContext, identity: ContextIdentity, verdict: CaptureVerdict) {
        self.context = context
        self.identity = identity
        self.verdict = verdict
    }
}

public struct IndicatorInput: Sendable, Equatable {
    public var accessibilityGranted: Bool
    public var isPaused: Bool
    /// Nil when no app, or Remora itself, is frontmost.
    public var frontmost: FrontmostApp?
    public var observed: ObservedWindow?

    public init(accessibilityGranted: Bool, isPaused: Bool, frontmost: FrontmostApp?, observed: ObservedWindow?) {
        self.accessibilityGranted = accessibilityGranted
        self.isPaused = isPaused
        self.frontmost = frontmost
        self.observed = observed
    }
}

public enum IndicatorStatus: Sendable, Hashable {
    case capturing, notCapturing(CaptureVerdict), paused, pending, unknown, noAccessibility
}

public enum IndicatorDot: Sendable, Equatable {
    case capturing, notCapturing
}

public struct IndicatorState: Sendable, Equatable {
    public var status: IndicatorStatus
    public var appName: String?
    public var site: String?
    public var pid: Int32?
    public var window: Int?

    public init(status: IndicatorStatus, appName: String? = nil, site: String? = nil,
                pid: Int32? = nil, window: Int? = nil) {
        self.status = status
        self.appName = appName
        self.site = site
        self.pid = pid
        self.window = window
    }

    public var displayName: String? { site ?? appName }

    public static let initial = IndicatorState(status: .unknown)

    public static func reduce(_ input: IndicatorInput) -> IndicatorState {
        guard input.accessibilityGranted else { return IndicatorState(status: .noAccessibility) }
        guard let front = input.frontmost else { return .initial }
        if input.isPaused {
            return IndicatorState(status: .paused, appName: front.name, pid: front.pid)
        }
        guard let seen = input.observed, seen.identity.pid == front.pid else {
            switch front.appVerdict {
            case .some(.passwordManager): return IndicatorState(status: .notCapturing(.passwordManager), appName: front.name, pid: front.pid)
            case .some(.userExcluded(let p)): return IndicatorState(status: .notCapturing(.userExcluded(pattern: p)), appName: front.name, pid: front.pid)
            case .some(.rulesUnavailable): return IndicatorState(status: .notCapturing(.rulesUnavailable), appName: front.name, pid: front.pid)
            default: return IndicatorState(status: .pending, appName: front.name, pid: front.pid)
            }
        }
        let ctx = seen.context
        var site: String?
        if BrowserCatalog.isBrowser(ctx.bundleID), !ctx.isPrivateBrowsing, seen.verdict != .privateWindow,
           var host = ctx.domain {
            if host.hasPrefix("www.") { host.removeFirst(4) }
            site = host.isEmpty ? nil : host
        }
        return IndicatorState(
            status: seen.verdict == .allowed ? .capturing : .notCapturing(seen.verdict),
            appName: ctx.app, site: site, pid: seen.identity.pid, window: seen.identity.window)
    }

    /// The menu-bar dot. `previous` keeps the colour steady while a new app's sample is pending.
    public func dot(previous: IndicatorDot?) -> IndicatorDot? {
        switch status {
        case .capturing: .capturing
        case .notCapturing, .unknown: .notCapturing
        case .pending: previous ?? .notCapturing
        case .paused, .noAccessibility: nil
        }
    }
}

extension IndicatorStatus {
    /// A log-safe name: the kind only, never a rule pattern.
    public var kind: String {
        switch self {
        case .capturing: "capturing"
        case .paused: "paused"
        case .pending: "pending"
        case .unknown: "unknown"
        case .noAccessibility: "noAccessibility"
        case .notCapturing(let v):
            switch v {
            case .allowed: "notCapturing.allowed"
            case .rulesUnavailable: "notCapturing.rulesUnavailable"
            case .privateWindow: "notCapturing.privateWindow"
            case .unknownURL: "notCapturing.unknownURL"
            case .passwordManager: "notCapturing.passwordManager"
            case .sensitiveSite: "notCapturing.sensitiveSite"
            case .signInPage: "notCapturing.signInPage"
            case .userExcluded: "notCapturing.userExcluded"
            }
        }
    }
}

/// Whether a cached verdict may be reused for an unchanged context. A `.rulesUnavailable`
/// (a transient read failure, fail-closed) is never reused: it is re-fetched on the next sample.
/// A verdict is also not reused while `stale` (a rule reload is pending).
public func shouldReuseVerdict(_ verdict: CaptureVerdict?, stale: Bool = false) -> Bool {
    guard !stale, let verdict else { return false }
    return verdict != .rulesUnavailable
}
