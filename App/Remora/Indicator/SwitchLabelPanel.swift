import AppKit
import Indicator
import SwiftUI

/// The ~1.5 s "Capturing Slack" label under the menu-bar item. Non-activating, click-through,
/// never key, hidden from screen sharing. A new `show` replaces the text and restarts the timer.
@MainActor
final class SwitchLabelPanel {
    private static let fadeIn: TimeInterval = 0.15
    private static let hold: TimeInterval = 1.5
    private static let fadeOut: TimeInterval = 0.2

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private let panel: Panel
    private let host: NSHostingView<LabelView>
    private var hideTask: Task<Void, Never>?
    private var generation = 0

    init() {
        host = NSHostingView(rootView: LabelView(text: ""))
        panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                      backing: .buffered, defer: true)
        panel.contentView = host
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.alphaValue = 0
    }

    func show(_ text: String) {
        generation += 1
        let mine = generation
        hideTask?.cancel()
        host.rootView = LabelView(text: text)
        let size = host.fittingSize
        let status = NSApp.windows.first { $0.className == "NSStatusBarWindow" }
        // The status item's own screen (the one holding its status-bar window), not the key screen.
        let screen = status?.screen ?? NSScreen.main
        guard let screen else { return }
        let frame = SwitchLabelLayout.frame(
            labelSize: size, statusItemFrame: status?.frame, visibleFrame: screen.visibleFrame)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.fadeIn
            panel.animator().alphaValue = 1
        }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.hold))
            guard !Task.isCancelled, let self, self.generation == mine else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = Self.fadeOut
                self.panel.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    if self.generation == mine { self.panel.orderOut(nil) }
                }
            })
        }
    }
}

private struct LabelView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: 360)
            .background(.regularMaterial, in: Capsule())
            .fixedSize(horizontal: false, vertical: true)
    }
}
