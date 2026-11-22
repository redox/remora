import AppKit
import Capture
import SwiftUI

/// The dictation HUD: a borderless, non-activating panel centred near the bottom of the screen that
/// holds the frontmost window. It shows notices without taking focus from the writing popover.
@MainActor
final class DictationHUDPanel {
    static let width: CGFloat = 360
    static let height: CGFloat = 96
    /// From the bottom of the screen's visible frame to the HUD's bottom edge.
    private static let bottomInset: CGFloat = 120

    /// Clicks land on the first mouse-down even though the panel is not key.
    private final class Host: NSHostingView<DictationHUDView> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private let panel: NSPanel
    private let host: Host
    private let windows: FrontmostWindowReader
    /// Bumped by every show and hide: a late window-geometry read never moves a newer HUD.
    private var placement = 0

    init(controller: DictationController, windows: FrontmostWindowReader) {
        self.windows = windows
        host = Host(rootView: DictationHUDView(controller: controller))
        panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: Self.width, height: Self.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.contentView = host
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    /// Shows the HUD (it follows the controller's state). Placed on the main screen at once, then
    /// moved to the screen of the frontmost window once its geometry is read.
    func show() {
        placement += 1
        let mine = placement
        if !panel.isVisible {
            place(on: (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame)
            panel.orderFrontRegardless()
        }
        let windows = windows
        Task { [weak self] in
            guard let geometry = await windows.readFocusedWindowGeometry(), let self,
                  mine == self.placement, self.panel.isVisible else { return }
            self.place(on: ScreenPlacement.visibleFrame(for: ScreenPlacement.cocoa(fromAX: geometry.frame)))
        }
    }

    func hide() {
        placement += 1
        panel.orderOut(nil)
    }

    private func place(on visible: CGRect?) {
        guard let visible else { return }
        panel.setFrame(CGRect(x: (visible.midX - Self.width / 2).rounded(), y: visible.minY + Self.bottomInset,
                              width: Self.width, height: Self.height), display: true)
    }
}
