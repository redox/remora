import AppKit
import Input
import Rewrite
import SwiftUI

/// The small fish at the caret while a rewrite works (click to cancel), the subtle hold hint, and
/// the short notice bubble after a rewrite. Borderless, non-activating, never key, `.statusBar` level.
@MainActor
final class CaretIndicatorPanel {
    static let hintSize = CGSize(width: 18, height: 18)
    static let workingSize = CGSize(width: 86, height: 28)
    private static let noticeWidth: CGFloat = 320
    private static let noticeDuration: Duration = .seconds(4)

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// Clicks land on the first mouse-down even though the panel is never key.
    private final class Host: NSHostingView<IndicatorView> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private enum Content { case none, working, hint, notice }

    private let panel: Panel
    private let host: Host
    private var content: Content = .none
    private var hideTask: Task<Void, Never>?

    init() {
        host = Host(rootView: IndicatorView(kind: .hidden))
        panel = Panel(contentRect: CGRect(origin: .zero, size: Self.hintSize),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.contentView = host
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    }

    var isShowingHint: Bool { content == .hint }

    /// The working badge next to the focused field's caret.
    func showWorking(in field: FocusedField, onCancel: @escaping @MainActor () -> Void) {
        show(.working, kind: .working(onCancel: onCancel), in: field)
    }

    /// The subtle hint while the rewrite key is held (Rewrite mode on release).
    func showHint(in field: FocusedField) {
        show(.hint, kind: .hint, in: field)
    }

    /// A short note for 4 s, with its action button when it has one.
    func showNotice(_ notice: RewriteNotice, in field: FocusedField?, onAction: @escaping @MainActor (RewriteNotice.Action) -> Void) {
        hideTask?.cancel()
        content = .notice
        let caret = ScreenPlacement.placement(for: field).indicatorAnchor(pointer: NSEvent.mouseLocation)
        let visible = ScreenPlacement.visibleFrame(for: caret)
        let width = min(Self.noticeWidth, visible.width)
        host.rootView = IndicatorView(kind: .notice(notice, width: width, onAction: { [weak self] action in
            self?.hide()
            onAction(action)
        }, onDismiss: { [weak self] in self?.hide() }))
        panel.ignoresMouseEvents = false
        let size = host.fittingSize
        let origin = Self.noticeOrigin(size: size, anchor: caret, visible: visible)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.noticeDuration)
            guard !Task.isCancelled, let self, self.content == .notice else { return }
            self.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        content = .none
        panel.orderOut(nil)
        host.rootView = IndicatorView(kind: .hidden)
    }

    func hideHint() {
        if content == .hint { hide() }
    }

    // MARK: -

    private func show(_ c: Content, kind: IndicatorView.Kind, in field: FocusedField) {
        hideTask?.cancel()
        content = c
        host.rootView = IndicatorView(kind: kind)
        panel.ignoresMouseEvents = c == .hint
        let anchor = ScreenPlacement.placement(for: field).indicatorAnchor(pointer: NSEvent.mouseLocation)
        let size = c == .working ? Self.workingSize : Self.hintSize
        let frame = RewriteFlow.indicatorFrame(caret: anchor, size: size,
                                               visible: ScreenPlacement.visibleFrame(for: anchor))
        panel.setFrame(frame, display: true)
        host.layoutSubtreeIfNeeded()
        panel.orderFrontRegardless()
    }

    /// Below the caret, or above it when that would leave the screen; kept on screen.
    private static func noticeOrigin(size: CGSize, anchor: CGRect, visible: CGRect) -> CGPoint {
        var y = anchor.minY - 6 - size.height
        if y < visible.minY { y = anchor.maxY + 6 }
        let x = min(max(anchor.minX, visible.minX), max(visible.minX, visible.maxX - size.width))
        y = min(max(y, visible.minY), max(visible.minY, visible.maxY - size.height))
        return CGPoint(x: x, y: y)
    }
}

struct IndicatorView: View {
    enum Kind {
        case hidden
        case working(onCancel: @MainActor () -> Void)
        case hint
        case notice(RewriteNotice, width: CGFloat, onAction: @MainActor (RewriteNotice.Action) -> Void,
                    onDismiss: @MainActor () -> Void)
    }

    let kind: Kind
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        switch kind {
        case .hidden:
            Color.clear.frame(width: CaretIndicatorPanel.hintSize.width, height: CaretIndicatorPanel.hintSize.height)
        case .working(let onCancel):
            RewriteWorkingBadge(onCancel: onCancel)
        case .hint:
            RewriteBadgeSurface()
                .overlay {
                    RemoraGlyph().frame(width: 9, height: 9)
                        .foregroundStyle(RemoraBrand.accent(scheme).opacity(0.6))
                }
                .frame(width: CaretIndicatorPanel.hintSize.width, height: CaretIndicatorPanel.hintSize.height)
                .accessibilityLabel("Release to open Rewrite mode")
        case .notice(let notice, let width, let onAction, let onDismiss):
            WritingNoticeView(notice: notice, onAction: onAction)
                // Give the text its final width before the hosting view measures the wrapped height.
                .frame(width: width)
                .modifier(OverlaySurface(cornerRadius: 9))
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }
        }
    }

}

/// Keep a solid backing under the tiny mark when accessibility settings remove translucency.
private struct RewriteBadgeSurface: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var size = CGSize(width: 14, height: 14)

    var body: some View {
        Capsule().fill(.regularMaterial)
            .overlay {
                Capsule().fill(Color(nsColor: .windowBackgroundColor).opacity(reduceTransparency ? 1 : 0.94))
            }
            .overlay { Capsule().fill(RemoraBrand.accent(scheme).opacity(0.08)) }
            .overlay {
                Capsule().strokeBorder(Color.primary.opacity(contrast == .increased ? 0.55 : 0.22), lineWidth: 1)
            }
            .frame(width: size.width, height: size.height)
    }
}

/// A light orbit shows work without flashing the glyph. Hover exposes the existing cancel
/// action; Reduce Motion keeps the arc still. The panel remains non-key and never steals typing.
private struct RewriteWorkingBadge: View {
    let onCancel: @MainActor () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    @State private var spinning = false

    var body: some View {
        Button(action: onCancel) {
            HStack(spacing: 6) {
                ZStack {
                    Circle().trim(from: 0.05, to: 0.32)
                        .stroke(RemoraBrand.accent(scheme), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                        .frame(width: 18, height: 18)
                        .rotationEffect(.degrees(spinning && !reduceMotion ? 360 : 0))
                        .animation(reduceMotion ? nil : .linear(duration: 1.8).repeatForever(autoreverses: false), value: spinning)
                    if hovered {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(RemoraBrand.accent(scheme))
                    } else {
                        RemoraGlyph().frame(width: 13, height: 13)
                            .foregroundStyle(RemoraBrand.accent(scheme))
                    }
                }
                .accessibilityHidden(true)
                Text("Writing…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .frame(width: CaretIndicatorPanel.workingSize.width, height: CaretIndicatorPanel.workingSize.height)
            .background { RewriteBadgeSurface(size: CaretIndicatorPanel.workingSize) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .onAppear { spinning = !reduceMotion }
        .onChange(of: reduceMotion) { spinning = !reduceMotion }
        .help("Writing… Click or press Esc to cancel")
        .accessibilityLabel("Remora is writing. Click to cancel.")
    }
}
