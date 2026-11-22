import CoreGraphics

public enum ScreenGeometry {
    /// AX rects are global with the origin at the top-left of the primary screen; Cocoa's origin is
    /// its bottom-left: y' = h − y − height.
    public static func cocoaRect(fromAX r: CGRect, primaryScreenHeight h: CGFloat) -> CGRect {
        CGRect(x: r.origin.x, y: h - r.origin.y - r.height, width: r.width, height: r.height)
    }
}
