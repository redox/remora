import Capture
import CoreGraphics

/// Everything that decides whether the per-window badge is visible.
public struct BadgeConditions: Sendable, Equatable {
    public var enabled: Bool
    public var state: IndicatorState
    public var geometry: WindowGeometry?
    public var isInteracting: Bool
    public var sharingDetected: Bool
    public var primaryScreenHeight: CGFloat
    /// Cocoa coordinates.
    public var screenFrames: [CGRect]

    public init(enabled: Bool, state: IndicatorState, geometry: WindowGeometry?, isInteracting: Bool,
                sharingDetected: Bool, primaryScreenHeight: CGFloat, screenFrames: [CGRect]) {
        self.enabled = enabled
        self.state = state
        self.geometry = geometry
        self.isInteracting = isInteracting
        self.sharingDetected = sharingDetected
        self.primaryScreenHeight = primaryScreenHeight
        self.screenFrames = screenFrames
    }
}

/// Placement and visibility of the optional per-window badge.
public enum WindowBadge {
    public static let size = CGSize(width: 16, height: 16)
    public static let inset = CGSize(width: 8, height: 6)
    public static let minimumWindowSize = CGSize(width: 240, height: 120)

    /// AX frame (primary display's top-left origin, y down) to Cocoa (bottom-left, y up).
    /// Valid across displays, including ones above or left of the primary.
    public static func cocoaFrame(ofAXFrame ax: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: ax.minX, y: primaryScreenHeight - ax.minY - ax.height, width: ax.width, height: ax.height)
    }

    /// The badge's frame at the window's top-right corner (Cocoa coordinates).
    public static func panelFrame(forWindow cocoaFrame: CGRect) -> CGRect {
        CGRect(x: cocoaFrame.maxX - inset.width - size.width,
               y: cocoaFrame.maxY - inset.height - size.height,
               width: size.width, height: size.height)
    }

    public static func shouldShow(_ c: BadgeConditions) -> Bool {
        guard c.enabled, !c.isInteracting, !c.sharingDetected else { return false }
        switch c.state.status {
        case .capturing, .notCapturing, .paused: break
        case .pending, .unknown, .noAccessibility: return false
        }
        guard let g = c.geometry, g.pid == c.state.pid,
              c.state.window == nil || c.state.window == g.window else { return false }
        guard !g.isFullScreen, g.isStandardWindow,
              g.frame.width >= minimumWindowSize.width,
              g.frame.height >= minimumWindowSize.height else { return false }
        let cocoa = cocoaFrame(ofAXFrame: g.frame, primaryScreenHeight: c.primaryScreenHeight)
        guard !c.screenFrames.contains(where: { approximatelyEqual($0, cocoa) }) else { return false }
        let panel = panelFrame(forWindow: cocoa)
        return c.screenFrames.contains { $0.contains(panel) }
    }

    private static func approximatelyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 1) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}
