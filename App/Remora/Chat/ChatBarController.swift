import AppKit
import ChatBar
import Observation
import os
import Storage
import SwiftUI

/// What the bar's SwiftUI root shows; the controller sets it with every layout.
@MainActor @Observable
final class BarViewState {
    var expanded = false
    /// Panel-local, top-left origin.
    var card: CGRect = .zero
    var capsule: CGRect = .zero
    var hovered = false
    var pinned = false
    var settings = BarSettings()
}

/// Drives the chat bar: one `ChatPanel` on the primary screen, collapsed to a thin capsule at the
/// configured edge and expanded to the chat on hover, click, the menu or the rewrite key.
/// `BarInteraction` decides; this applies its effects (frames from `BarGeometry`, timers, focus).
///
/// It never activates Remora: the panel takes key focus only when the composer needs it, and
/// never on a hover expand (a key panel would turn the peek into an open bar).
@MainActor
final class ChatBarController: NSObject, NSWindowDelegate {
    struct Actions {
        var openSettings: @MainActor () -> Void = {}
        var openAccountSettings: @MainActor () -> Void = {}
    }

    static let defaultSize = CGSize(width: 420, height: 520)
    static let minSize = CGSize(width: 320, height: 280)
    private static let log = Logger(subsystem: "dev.remora", category: "bar")

    let state = BarViewState()
    var actions = Actions()

    private let model: ChatModel
    private let store: SettingsStore
    private let panel = ChatPanel()
    private var interaction: BarInteraction
    private var settings: BarSettings
    private var hoverTimer: Task<Void, Never>?
    private var exitTimer: Task<Void, Never>?
    private var screenObserver: (any NSObjectProtocol)?
    private var started = false
    /// The interaction state the panel was last laid out for.
    private var laidOut: BarInteraction.State?

    init(model: ChatModel, settings: SettingsStore) {
        self.model = model
        store = settings
        let s = Self.load(settings)
        self.settings = s
        interaction = BarInteraction(pinned: s.pinned)
        super.init()
    }

    private static func load(_ store: SettingsStore) -> BarSettings {
        do { return try store.value(BarSettings.self, forKey: BarSettings.key) ?? BarSettings() } catch {
            log.error("bar settings unreadable; using defaults")
            return BarSettings()
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        let host = BarHostingView(rootView: ChatBarRootView(state: state, model: model, bar: self))
        host.sizingOptions = []
        panel.contentView = host
        panel.delegate = self
        panel.installTracking()
        panel.onEscape = { [weak self] in self?.handle(.escape) }
        panel.onMouseEntered = { [weak self] in self?.hover(true) }
        panel.onMouseExited = { [weak self] in self?.hover(false) }
        model.onStreamingChange = { [weak self] on in self?.handle(.streaming(on)) }
        model.fieldEditor = { [weak panel] in panel?.firstResponder as? NSTextView }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
        // A pinned bar starts open (`BarInteraction(pinned: true)`): show it expanded, without focus.
        layout()
        panel.orderFrontRegardless()
    }

    // MARK: - Commands

    /// The menu's "Open chat": opens with the composer focused, or collapses.
    func toggle() { handle(.toggle) }

    func open(focusInput: Bool) {
        handle(.openRequested, focus: focusInput)
    }

    /// Opens the chat on an inbox message (a notification click).
    func openMessage(inboxID: Int64) {
        model.reveal(inboxID: inboxID)
        handle(.openRequested, focus: false)
    }

    /// New bar settings (Settings › Appearance, or a chat action): re-lays out the bar.
    func apply(_ s: BarSettings) {
        let pinChanged = s.pinned != interaction.pinned
        settings = s
        state.settings = s
        if pinChanged { handle(.setPinned(s.pinned)) }
        layout()
    }

    /// Re-reads the stored bar settings and applies them.
    func reloadSettings() { apply(Self.load(store)) }

    /// The settings the bar runs with (Settings › Appearance reads them).
    var current: BarSettings { settings }

    /// Settings › Appearance: changes one field of the live settings (keeping the pin and sizes the
    /// bar itself saved), persists to `chat.bar` and applies at once.
    func update(_ change: (inout BarSettings) -> Void) {
        var s = settings
        change(&s)
        guard s != settings else { return }
        settings = s
        save()
        apply(s)
    }

    func setPinned(_ on: Bool) {
        settings.pinned = on
        save()
        handle(.setPinned(on))
    }

    func collapse() {
        guard interaction.state != .collapsed else { return }
        handle(.toggle)
    }

    func clickBar() { handle(.clickBar) }

    // MARK: - Interaction

    private func hover(_ inside: Bool) {
        state.hovered = inside
        handle(inside ? .mouseEntered : .mouseExited)
    }

    private func handle(_ input: BarInteraction.Input, focus: Bool = true) {
        let effects = interaction.handle(input, openOnHover: settings.openOnHover)
        var focusAfterLayout = false
        for effect in effects {
            switch effect {
            case .expand, .collapse: break  // the state change below lays the panel out
            case .startHoverTimer(let t): hoverTimer = after(t) { $0.handle(.hoverTimerFired) }
            case .startExitTimer(let t): exitTimer = after(t) { $0.handle(.exitTimerFired) }
            case .cancelTimers:
                hoverTimer?.cancel(); hoverTimer = nil
                exitTimer?.cancel(); exitTimer = nil
            case .focusInput:
                focusAfterLayout = focus
            case .stopStream: model.stop()
            }
        }
        state.pinned = interaction.pinned
        if interaction.state != laidOut { layout() }
        // Becoming key can synchronously call the delegate. Settle the window and its content
        // coordinates first, so that callback cannot promote a half-laid-out hover panel.
        if focusAfterLayout {
            panel.makeKeyAndOrderFront(nil)  // a non-activating panel: Remora stays inactive
            model.requestFocus()
        }
    }

    private func after(_ t: TimeInterval, _ body: @escaping @MainActor (ChatBarController) -> Void) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(t))
            guard !Task.isCancelled, let self else { return }
            body(self)
        }
    }

    // MARK: - Layout

    private func screen() -> ScreenInfo? {
        guard let s = NSScreen.screens.first else { return nil }
        // Global Cocoa coordinates (the primary screen's origin is 0,0, but stay correct anyway).
        func global(_ r: CGRect?) -> CGRect? {
            guard let r, !r.isEmpty else { return nil }
            return s.frame.contains(r) ? r : r.offsetBy(dx: s.frame.minX, dy: s.frame.minY)
        }
        return ScreenInfo(frame: s.frame, visibleFrame: s.visibleFrame, auxiliaryTopLeft: global(s.auxiliaryTopLeftArea),
                          auxiliaryTopRight: global(s.auxiliaryTopRightArea), safeAreaTop: s.safeAreaInsets.top)
    }

    private var expandedSize: CGSize {
        let stored = settings.expandedSizes[settings.position.rawValue] ?? Self.defaultSize
        return CGSize(width: max(stored.width, Self.minSize.width), height: max(stored.height, Self.minSize.height))
    }

    private func layout() {
        guard started, let s = screen() else { return }
        let p = settings.position
        let st = interaction.state
        laidOut = st
        state.settings = settings
        state.pinned = interaction.pinned
        let frame: CGRect
        var card: CGRect = .zero
        var capsule: CGRect = .zero
        switch st {
        case .collapsed:
            frame = BarGeometry.collapsedPanelFrame(p, s)
            let bar = BarGeometry.visibleBarRect(p, s)
            capsule = CGRect(x: bar.minX - frame.minX, y: frame.maxY - bar.maxY, width: bar.width, height: bar.height)
            panel.setResizable(false)
            // The open bar's limits must not stretch the 6 pt capsule.
            panel.contentMinSize = CGSize(width: 1, height: 1)
            panel.contentMaxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        case .peeking, .open:
            let screenCard = BarGeometry.expandedFrame(p, size: expandedSize, s)
            let placed = BarLayout.panel(card: screenCard, bar: st == .peeking ? BarGeometry.collapsedPanelFrame(p, s) : nil)
            frame = placed.frame
            card = placed.card
            panel.setResizable(st == .open)
            panel.contentMinSize = Self.minSize
            let max = BarGeometry.clampSize(CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude), s)
            panel.contentMaxSize = max
        }
        // Peek's window includes the notch, but open's window starts below it. Never animate
        // between those coordinate spaces while SwiftUI has already adopted the new card offset:
        // the header would pass through the camera housing. Publish the matching geometry in one
        // main-actor turn, with no intermediate redraw of the old content at the new origin.
        panel.setFrame(frame, display: false)
        state.card = card
        state.capsule = capsule
        state.expanded = st != .collapsed
        panel.hasShadow = state.expanded
        if st == .collapsed { giveKeyBack() }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// A collapsed bar takes no typing: hand the keyboard back to the user's app.
    private func giveKeyBack() {
        guard panel.isKeyWindow else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    private func save() {
        state.settings = settings
        do { try store.setValue(settings, forKey: BarSettings.key) } catch {
            Self.log.error("bar settings not saved")
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) { handle(.becameKey) }

    /// Losing key collapses an open, unpinned bar, except while a confirmation card waits (it must
    /// stay in view) or the bar's own details popover took the focus (tracked by the model; a
    /// child, sheet or popover key window is a fallback check).
    func windowDidResignKey(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self, !self.panel.isKeyWindow else { return }
            guard BarAppearance.collapsesOnResignKey(cardPending: self.model.pendingConfirmation != nil,
                                                     detailsOpen: self.model.detailsOpen) else { return }
            if let key = NSApp.keyWindow, key.parent === self.panel || key.sheetParent === self.panel
                || String(describing: type(of: key)).contains("Popover") { return }
            self.handle(.resignedKey)
        }
    }

    func windowDidResize(_ notification: Notification) {
        guard panel.inLiveResize else { return }
        state.card = CGRect(origin: .zero, size: panel.frame.size)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard interaction.state == .open else { return }
        settings.expandedSizes[settings.position.rawValue] = panel.frame.size
        save()
        state.card = CGRect(origin: .zero, size: panel.frame.size)
    }
}

/// Clicks land on the first mouse-down even though the panel is not key.
private final class BarHostingView: NSHostingView<ChatBarRootView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The capsule while collapsed, the chat card while expanded.
struct ChatBarRootView: View {
    let state: BarViewState
    let model: ChatModel
    let bar: ChatBarController

    var body: some View {
        // An overlay cannot grow its host to the card's fixed size while the window is still
        // collapsed. All offsets are panel-local; BarGeometry already accounts for safe areas.
        Color.clear.overlay(alignment: .topLeading) {
            if state.expanded {
                ChatView(model: model, bar: bar, pinned: state.pinned, textScale: state.settings.textScale,
                         height: state.card.height)
                    .frame(width: state.card.width, height: state.card.height)
                    .offset(x: state.card.minX, y: state.card.minY)
            } else {
                let style = BarAppearance.capsule(streaming: model.isStreaming,
                                                  awaitingAnswer: model.pendingConfirmation != nil)
                CollapsedBar(style: style, unseen: model.unseenCount > 0,
                             // A waiting card always shows, even on an auto-hidden or dimmed bar.
                             alpha: style == .awaitingAnswer ? 1 : BarAppearance.collapsedAlpha(state.settings, hovered: state.hovered),
                             vertical: state.capsule.height > state.capsule.width)
                    .frame(width: state.capsule.width, height: state.capsule.height)
                    .offset(x: state.capsule.minX, y: state.capsule.minY)
                    .onTapGesture { bar.clickBar() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .clipped()
    }
}

/// The 6 pt capsule: material, accent-tinted while a turn streams, orange while a confirmation
/// card waits, with a dot for unseen messages.
private struct CollapsedBar: View {
    let style: BarAppearance.CapsuleStyle
    let unseen: Bool
    let alpha: Double
    let vertical: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Capsule()
            .fill(.regularMaterial)
            .overlay(Capsule().fill(tint))
            .overlay(alignment: vertical ? .top : .trailing) {
                if unseen {
                    Circle().fill(RemoraBrand.accent(scheme)).frame(width: 5, height: 5).padding(vertical ? .top : .trailing, 4)
                }
            }
            .opacity(alpha)
            .contentShape(Rectangle())
            .accessibilityLabel(style == .awaitingAnswer ? "Remora chat, waiting for your answer"
                                : unseen ? "Remora chat, new messages" : "Remora chat")
            .accessibilityAddTraits(.isButton)
    }

    private var tint: Color {
        switch style {
        case .plain: .clear
        case .streaming: RemoraBrand.accent(scheme).opacity(0.55)
        case .awaitingAnswer: Color.orange.opacity(0.9)
        }
    }
}
