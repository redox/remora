import Capture

public enum IndicatorCopy {
    public static func label(_ s: IndicatorState) -> String? {
        guard let name = s.displayName else { return nil }
        switch s.status {
        case .capturing: return "Capturing \(name)"
        case .notCapturing: return "Not capturing \(name)"
        case .paused: return "Not capturing \(name) (paused)"
        case .pending, .unknown, .noAccessibility: return nil
        }
    }

    public static func headline(_ s: IndicatorState) -> String? {
        guard let label = label(s) else { return nil }
        if case .notCapturing(let v) = s.status, let r = reason(v) { return "\(label) — \(r)" }
        return label
    }

    public static func reason(_ v: CaptureVerdict) -> String? {
        switch v {
        case .allowed: nil
        case .privateWindow: "private window"
        case .unknownURL: "page address unknown"
        case .passwordManager: "password manager"
        case .sensitiveSite: "banking or password site"
        case .signInPage: "sign-in page"
        case .userExcluded: "on your ignore list"
        case .rulesUnavailable: "ignore list unreadable"
        }
    }
}
