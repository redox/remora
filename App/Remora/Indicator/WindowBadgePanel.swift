import AppKit
import Indicator

/// The optional 16x16 capture badge. Exactly the size of its icon, so it only ever intercepts
/// clicks on itself. Non-activating, never key or main, hidden from screen sharing (best effort).
@MainActor
final class WindowBadgePanel: NSPanel {
    var onClick: @MainActor () -> Void = {}

    private let imageView = NSImageView()
    private let background = BadgeBackground()

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        let size = WindowBadge.size
        super.init(contentRect: CGRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        sharingType = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]

        background.frame = CGRect(origin: .zero, size: size)
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = size.width / 2
        background.layer?.masksToBounds = true
        background.onClick = { [weak self] in self?.onClick() }

        imageView.frame = background.bounds
        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = .scaleNone
        background.addSubview(imageView)
        contentView = background
        setStatus(.capturing)
    }

    /// Icons for the visible statuses; other statuses leave the image unchanged (the badge is
    /// hidden for them).
    func setStatus(_ s: IndicatorStatus) {
        let symbol: String, color: NSColor, label: String
        switch s {
        case .capturing: (symbol, color, label) = ("fish.fill", .systemOrange, "Remora is capturing this window")
        case .notCapturing: (symbol, color, label) = ("fish", .secondaryLabelColor, "Remora is not capturing this window")
        case .paused: (symbol, color, label) = ("pause.fill", .secondaryLabelColor, "Remora capture is paused")
        case .pending, .unknown, .noAccessibility: return
        }
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            .applying(.init(paletteColors: [color]))
        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(config)
        imageView.setAccessibilityLabel(label)
    }
}

private final class BadgeBackground: NSVisualEffectView {
    var onClick: @MainActor () -> Void = {}
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        MainActor.assumeIsolated { onClick() }
    }
}
