import CoreGraphics

/// Geometry of an app's focused window, read through AX (never from window images).
public struct WindowGeometry: Sendable, Equatable {
    public var pid: Int32
    /// Same key as `ContextIdentity.window` (`Int(bitPattern: CFHash(element))`).
    public var window: Int
    /// AX coordinates: origin at the primary display's top-left, y down.
    public var frame: CGRect
    public var isFullScreen: Bool
    public var isStandardWindow: Bool

    public init(pid: Int32, window: Int, frame: CGRect, isFullScreen: Bool, isStandardWindow: Bool) {
        self.pid = pid
        self.window = window
        self.frame = frame
        self.isFullScreen = isFullScreen
        self.isStandardWindow = isStandardWindow
    }
}
