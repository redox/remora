import AppKit
import Capture
import Input
import Rewrite

/// AX rects (top-left origin) to Cocoa screen coordinates, and the screen they sit on.
@MainActor
enum ScreenPlacement {
    static func placement(for field: FocusedField?, context: WindowContext? = nil,
                          googleDocsCaret: CGRect? = nil) -> WritingOverlayPlacement {
        WritingOverlayPlacement(field: field, context: context, googleDocsCaret: googleDocsCaret,
                                primaryScreenHeight: NSScreen.screens.first?.frame.height ?? 0)
    }

    /// The visible frame of the screen holding the rect's centre (else the main screen).
    static func visibleFrame(for r: CGRect) -> CGRect {
        let center = CGPoint(x: r.midX, y: r.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main ?? NSScreen.screens.first
        return screen?.visibleFrame ?? r
    }
}
