import AppKit
import Capture
import Indicator
import os

/// Owns the optional badge: when to read the focused window's geometry, when to show or hide.
///
/// While disabled nothing is read, the monitor is stopped and the panel is ordered out. Reads
/// are one at a time (a trigger during a read marks it dirty and it is redone). Moved/resized
/// hides the badge and re-reads 250 ms after the last event, once no mouse button is held.
/// Logs carry no names, titles or geometry.
@MainActor
final class WindowBadgeController {
    private static let settleDelay: Duration = .milliseconds(250)

    private let reader: FrontmostWindowReader
    private let indicator: IndicatorController
    private let perform: @MainActor (QuickMenuItem) -> Void
    private let panel = WindowBadgePanel()
    private let monitor = ScreenShareMonitor()

    private var enabled = false
    private var geometry: WindowGeometry?
    private var isInteracting = false
    private var sharingDetected = false
    private var reading = false
    private var dirty = false
    private var settleTask: Task<Void, Never>?
    private var observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []
    private var menuActions: [MenuAction] = []

    init(reader: FrontmostWindowReader, indicator: IndicatorController,
         perform: @escaping @MainActor (QuickMenuItem) -> Void) {
        self.reader = reader
        self.indicator = indicator
        self.perform = perform
        panel.onClick = { [weak self] in self?.showMenu() }
        monitor.onChange = { [weak self] sharing in
            self?.sharingDetected = sharing
            self?.evaluate()
        }
    }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            panel.setStatus(indicator.state.status)
            observeSystem()
            monitor.start()
            requestRead()
        } else {
            for (center, token) in observers { center.removeObserver(token) }
            observers = []
            monitor.stop()
            sharingDetected = false
            settleTask?.cancel()
            settleTask = nil
            isInteracting = false
            dirty = false
            geometry = nil
            panel.orderOut(nil)
        }
    }

    func windowEvent(_ e: CaptureScheduler.WindowEvent) {
        guard enabled else { return }
        switch e {
        case .appActivated, .focusedWindowChanged:
            geometry = nil
            evaluate()
            requestRead()
        case .movedOrResized:
            geometry = nil
            isInteracting = true
            dirty = true  // a read already in flight is stale
            evaluate()
            armSettleTimer()
        }
    }

    /// The indicator state changed: update the icon and re-evaluate without a read.
    func stateChanged() {
        guard enabled else { return }
        let state = indicator.state
        panel.setStatus(state.status)
        // The badge must never float over a different window than the indicator describes.
        if let g = geometry, state.pid != g.pid || state.window != g.window {
            geometry = nil
            panel.orderOut(nil)
            requestRead()
            return
        }
        evaluate()
    }

    // MARK: - Reads

    private func armSettleTimer() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled, let self else { return }
            self.settled()
        }
    }

    private func settled() {
        guard enabled else { return }
        if NSEvent.pressedMouseButtons != 0 {
            armSettleTimer()
            return
        }
        isInteracting = false
        requestRead()
    }

    private func requestRead() {
        guard enabled else { return }
        if reading {
            dirty = true
            return
        }
        reading = true
        dirty = false
        Task { [weak self, reader] in
            let geometry = await reader.readFocusedWindowGeometry()
            self?.readFinished(geometry)
        }
    }

    private func readFinished(_ read: WindowGeometry?) {
        reading = false
        guard enabled else { return }
        // During a drag or resize the result is stale on arrival; the settle timer reads.
        if isInteracting {
            dirty = false
            return
        }
        if dirty {
            requestRead()
            return
        }
        geometry = read
        evaluate()
    }

    // MARK: - Visibility

    private func evaluate() {
        guard enabled, let primary = NSScreen.screens.first else {
            panel.orderOut(nil)
            return
        }
        let conditions = BadgeConditions(
            enabled: enabled, state: indicator.state, geometry: geometry,
            isInteracting: isInteracting, sharingDetected: sharingDetected,
            primaryScreenHeight: primary.frame.height,
            screenFrames: NSScreen.screens.map(\.frame))
        guard WindowBadge.shouldShow(conditions), let geometry else {
            panel.orderOut(nil)
            return
        }
        let cocoa = WindowBadge.cocoaFrame(ofAXFrame: geometry.frame, primaryScreenHeight: primary.frame.height)
        panel.setFrame(WindowBadge.panelFrame(forWindow: cocoa), display: false)
        panel.orderFrontRegardless()
    }

    private func observeSystem() {
        let screens = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.requestRead() } }
        let spaces = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.geometry = nil
                self?.panel.orderOut(nil)
                self?.requestRead()
            }
        }
        observers = [(NotificationCenter.default, screens), (NSWorkspace.shared.notificationCenter, spaces)]
    }

    // MARK: - Menu

    private func showMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let headline = IndicatorCopy.headline(indicator.state) {
            let item = NSMenuItem(title: headline, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
        }
        // NSMenuItem.target is weak: keep the actions alive until the next showMenu.
        let quickItems = QuickMenu.items(for: indicator.state)
        menuActions = quickItems.map { quick in
            MenuAction { [weak self] in self?.perform(quick) }
        }
        for (quick, action) in zip(quickItems, menuActions) {
            let item = NSMenuItem(title: quick.title, action: #selector(MenuAction.fire), keyEquivalent: "")
            item.target = action
            menu.addItem(item)
        }
        guard let view = panel.contentView else { return }
        // Below the badge: the content view is not flipped, so its bottom edge is y = 0.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -2), in: view)
    }
}

@MainActor
private final class MenuAction: NSObject {
    private let handler: @MainActor () -> Void
    init(_ handler: @escaping @MainActor () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}
