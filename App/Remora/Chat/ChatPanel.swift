import AppKit
import Assistant

/// The chat bar's window: a borderless, non-activating floating panel on every Space. It can
/// become key (the composer takes typing) without activating Remora, so the user's app stays
/// frontmost, and capture keeps reading that app, never this panel. Hidden from screen sharing
/// and screenshots (best effort), like Remora's other panels.
@MainActor
final class ChatPanel: NSPanel {
    var onEscape: @MainActor () -> Void = {}
    var onMouseEntered: @MainActor () -> Void = {}
    var onMouseExited: @MainActor () -> Void = {}

    static let baseStyle: NSWindow.StyleMask = [.nonactivatingPanel, .borderless, .fullSizeContentView]

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 200, height: 6), styleMask: Self.baseStyle,
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        // Explicitly opt out of alpha-based window hit testing. Leaving the default untouched
        // lets gestures over the composited card reach the app underneath, before sendEvent.
        ignoresMouseEvents = false
        hasShadow = false
        isReleasedWhenClosed = false
        isMovable = false
        sharingType = .none
        animationBehavior = .none
    }

    /// Resizable only while open (the user drags an edge; the size is stored per position).
    func setResizable(_ on: Bool) {
        let mask = on ? Self.baseStyle.union(.resizable) : Self.baseStyle
        if styleMask != mask { styleMask = mask }
    }

    /// Installs the hover tracking area on the content view (it follows the view's bounds).
    func installTracking() {
        guard let view = contentView else { return }
        view.trackingAreas.forEach(view.removeTrackingArea)
        view.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onMouseEntered() }
    override func mouseExited(with event: NSEvent) { onMouseExited() }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
            // Esc: stop the stream, or collapse; but while an input method composes, it is the IME's.
            let composing = (firstResponder as? NSTextView)?.hasMarkedText() ?? false
            if event.keyCode == 53, flags.isEmpty, ChatPresentation.barTakesEscape(composing: composing) {
                onEscape()
                return
            }
        }
        super.sendEvent(event)
    }

    /// Remora is not active, so the main menu's Edit items may not see these: route them to the
    /// first responder directly.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if let key = event.charactersIgnoringModifiers?.lowercased() {
            let action: Selector? = switch (flags, key) {
            case (.command, "x"): #selector(NSText.cut(_:))
            case (.command, "c"): #selector(NSText.copy(_:))
            case (.command, "v"): #selector(NSText.paste(_:))
            case (.command, "a"): #selector(NSText.selectAll(_:))
            case (.command, "z"): Selector(("undo:"))
            case ([.command, .shift], "z"): Selector(("redo:"))
            default: nil
            }
            if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}
