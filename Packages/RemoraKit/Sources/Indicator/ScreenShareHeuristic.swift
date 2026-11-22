import CoreGraphics

/// Metadata of an on-screen window (owner, layer, bounds). Never a title or an image.
public struct OnScreenWindow: Sendable, Equatable {
    public var ownerBundleID: String?
    public var layer: Int
    public var bounds: CGRect
    public var alpha: Double

    public init(ownerBundleID: String?, layer: Int, bounds: CGRect, alpha: Double = 1) {
        self.ownerBundleID = ownerBundleID
        self.layer = layer
        self.bounds = bounds
        self.alpha = alpha
    }

    /// Idle invisible helper windows (Electron, meeting apps) are tiny or fully transparent;
    /// they must not count as a share toolbar. Applied by `ScreenShareHeuristic` itself, except
    /// for capture tools (their recording stop button is a small status-item window).
    public static let minimumSide: CGFloat = 40

    public static func isMeaningful(bounds: CGRect, alpha: Double) -> Bool {
        alpha > 0 && bounds.width >= minimumSide && bounds.height >= minimumSide
    }
}

/// Best-effort screen-share detection from raw `CGWindowListCopyWindowInfo` metadata only (no
/// Screen Recording permission); it applies the size/alpha filter itself.
///
/// Limits (D6): a known capture tool owning an on-screen window above layer 0, or a known
/// meeting/recording app owning a floating window (above layer 0, not the status-item layer),
/// such as a share toolbar or camera bubble. Browser-based sharing (Meet/Teams on the web) and
/// OBS are not detected; for those the badge panel's `sharingType = .none` is the only
/// mitigation, and it is best effort (ScreenCaptureKit may ignore it).
public enum ScreenShareHeuristic {
    public static let statusItemLayer = 25
    public static let captureTools: Set<String> = [
        "com.apple.screencaptureui", "com.apple.QuickTimePlayerX",
    ]
    public static let sharingApps: Set<String> = [
        "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "Cisco-Systems.Spark",
        "com.hnc.Discord", "com.tinyspeck.slackmacgap", "com.apple.FaceTime", "com.loom.desktop",
        "pl.maketheweb.cleanshotx",
    ]

    public static func isLikelySharing(_ windows: [OnScreenWindow]) -> Bool {
        windows.contains { window in
            guard let id = window.ownerBundleID, window.layer > 0 else { return false }
            if captureTools.contains(id) { return true }
            guard OnScreenWindow.isMeaningful(bounds: window.bounds, alpha: window.alpha) else { return false }
            return sharingApps.contains(id) && window.layer != statusItemLayer
        }
    }
}
