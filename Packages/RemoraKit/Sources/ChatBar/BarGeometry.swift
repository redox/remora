import Foundation
import CoreGraphics

/// Cocoa coordinates (origin bottom-left). The app fills this from `NSScreen`.
public struct ScreenInfo: Sendable, Equatable {
    public var frame: CGRect
    public var visibleFrame: CGRect
    public var auxiliaryTopLeft: CGRect?
    public var auxiliaryTopRight: CGRect?
    public var safeAreaTop: CGFloat

    public init(frame: CGRect, visibleFrame: CGRect, auxiliaryTopLeft: CGRect?, auxiliaryTopRight: CGRect?, safeAreaTop: CGFloat) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.auxiliaryTopLeft = auxiliaryTopLeft
        self.auxiliaryTopRight = auxiliaryTopRight
        self.safeAreaTop = safeAreaTop
    }
}

public enum BarGeometry {
    static let thickness: CGFloat = 6
    static let margin: CGFloat = 8

    /// An auto-hidden menu bar can make visibleFrame include the camera housing. Keep every
    /// expanded card below the hardware safe area, even when auxiliary notch areas are absent.
    private static func usableFrame(_ s: ScreenInfo) -> CGRect {
        let top = min(s.visibleFrame.maxY, s.frame.maxY - max(0, s.safeAreaTop))
        return CGRect(x: s.visibleFrame.minX, y: s.visibleFrame.minY,
                      width: s.visibleFrame.width, height: max(0, top - s.visibleFrame.minY))
    }

    public static func notch(_ s: ScreenInfo) -> CGRect? {
        guard let l = s.auxiliaryTopLeft, let r = s.auxiliaryTopRight, r.minX > l.maxX else { return nil }
        return CGRect(x: l.maxX, y: s.frame.maxY - s.safeAreaTop, width: r.minX - l.maxX, height: s.safeAreaTop)
    }

    public static func visibleBarRect(_ p: BarPosition, _ s: ScreenInfo) -> CGRect {
        let v = usableFrame(s)
        switch p {
        case .top:
            if let n = notch(s) { return CGRect(x: n.minX, y: n.minY - thickness, width: n.width, height: thickness) }
            return CGRect(x: s.frame.midX - 100, y: v.maxY - thickness, width: 200, height: thickness)
        case .left: return CGRect(x: v.minX, y: v.midY - 80, width: thickness, height: 160)
        case .right: return CGRect(x: v.maxX - thickness, y: v.midY - 80, width: thickness, height: 160)
        case .bottom: return CGRect(x: v.midX - 100, y: v.minY, width: 200, height: thickness)
        case .bottomLeft: return CGRect(x: v.minX + 12, y: v.minY, width: 120, height: thickness)
        case .bottomRight: return CGRect(x: v.maxX - 12 - 120, y: v.minY, width: 120, height: thickness)
        }
    }

    public static func collapsedPanelFrame(_ p: BarPosition, _ s: ScreenInfo) -> CGRect {
        let bar = visibleBarRect(p, s)
        guard p == .top else { return bar }
        if let n = notch(s) { return bar.union(n) }
        // No notch: also cover the menu-bar strip above the bar.
        return bar.union(CGRect(x: bar.minX, y: s.visibleFrame.maxY, width: bar.width, height: max(0, s.frame.maxY - s.visibleFrame.maxY)))
    }

    public static func clampSize(_ size: CGSize, _ s: ScreenInfo) -> CGSize {
        let area = usableFrame(s).insetBy(dx: margin, dy: margin)
        return CGSize(width: min(size.width, area.width), height: min(size.height, area.height))
    }

    public static func expandedFrame(_ p: BarPosition, size: CGSize, _ s: ScreenInfo) -> CGRect {
        let v = usableFrame(s)
        let sz = clampSize(size, s)
        let origin: CGPoint
        switch p {
        case .top:
            let midX = notch(s)?.midX ?? s.frame.midX
            origin = CGPoint(x: midX - sz.width / 2, y: v.maxY - sz.height)
        case .left: origin = CGPoint(x: v.minX + margin, y: v.midY - sz.height / 2)
        case .right: origin = CGPoint(x: v.maxX - margin - sz.width, y: v.midY - sz.height / 2)
        case .bottom: origin = CGPoint(x: v.midX - sz.width / 2, y: v.minY + margin)
        case .bottomLeft: origin = CGPoint(x: v.minX + margin, y: v.minY + margin)
        case .bottomRight: origin = CGPoint(x: v.maxX - margin - sz.width, y: v.minY + margin)
        }
        let area = v.insetBy(dx: margin, dy: margin)
        let x = min(max(origin.x, area.minX), area.maxX - sz.width)
        let y = min(max(origin.y, area.minY), area.maxY - sz.height)
        return CGRect(x: x, y: y, width: sz.width, height: sz.height)
    }
}
