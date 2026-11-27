import AppKit

/// The user explicitly opens this window to include the conversation in screenshots or screen sharing.
@MainActor
final class ChatWindow: NSWindow, NSWindowDelegate {
    private let onResignKey: () -> Void
    private let onClose: (ChatWindow) -> Void

    init(onResignKey: @escaping () -> Void, onClose: @escaping (ChatWindow) -> Void) {
        self.onResignKey = onResignKey
        self.onClose = onClose
        super.init(contentRect: NSRect(x: 0, y: 0, width: 760, height: 680),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                   backing: .buffered, defer: false)
        title = "Remora Chat"
        contentMinSize = NSSize(width: 320, height: 280)
        isReleasedWhenClosed = false
        isRestorable = false
        delegate = self
        center()
    }

    func windowDidResignKey(_ notification: Notification) { onResignKey() }

    func windowWillClose(_ notification: Notification) { onClose(self) }
}
