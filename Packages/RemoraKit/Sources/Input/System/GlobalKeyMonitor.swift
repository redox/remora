import AppKit
import Carbon.HIToolbox

/// Watches the rewrite key system-wide and reports clean taps, double taps and holds.
///
/// Global key monitors require only Accessibility; see docs/research/input-permissions.md.
/// It uses `NSEvent` global and local monitors only: no `CGEvent.tapCreate` and no IOHID APIs
/// (those need Input Monitoring). Events are observed, never consumed or modified.
///
/// Input the monitors never see is still caught: while Secure Event Input is on (a password field,
/// Terminal's Secure Keyboard Entry) the trigger is ignored, and every output is rejected when the
/// HID system state saw a key-down or click during the gesture (e.g. a hot key consumed by
/// Raycast or Alfred). A trigger pressed while a mouse button is down is a modifier.
@MainActor public final class GlobalKeyMonitor {
    private static let mask: NSEvent.EventTypeMask = [
        .flagsChanged, .keyDown, .systemDefined, .leftMouseDown, .rightMouseDown, .otherMouseDown,
        .leftMouseUp, .rightMouseUp, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        .scrollWheel,
    ]

    private var settings: ShortcutSettings
    private var detector: TapDetector
    private let allowsDoubleTap: @MainActor () -> Bool
    private let onOutput: @MainActor (TapDetector.Output) -> Void
    private var monitors: [Any] = []
    private var timer: Timer?

    public init(settings: ShortcutSettings, allowsDoubleTap: @escaping @MainActor () -> Bool = { true },
                onOutput: @escaping @MainActor (TapDetector.Output) -> Void) {
        self.settings = settings
        self.detector = Self.detector(for: settings)
        self.allowsDoubleTap = allowsDoubleTap
        self.onOutput = onOutput
    }

    isolated deinit { stop() }

    public func start() {
        guard monitors.isEmpty else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: Self.mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: Self.mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) { monitors.append(local) }
    }

    public func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        disarm()
        detector = Self.detector(for: settings)
    }

    public func update(_ s: ShortcutSettings) {
        settings = s
        detector = Self.detector(for: s)
        disarm()
    }

    private static func detector(for s: ShortcutSettings) -> TapDetector {
        TapDetector(doubleTap: s.doubleTapRewrites, hold: s.holdOpensEdit)
    }

    private func handle(_ event: NSEvent) {
        guard settings.rewriteKeyEnabled else { return }
        // `keyCode` is only defined for key events.
        let keyCode = event.type == .flagsChanged || event.type == .keyDown ? event.keyCode : 0
        guard var input = KeyEventClassifier.classify(type: event.type, keyCode: keyCode,
                                                      flags: event.modifierFlags.rawValue, trigger: settings.trigger,
                                                      mouseButtonsDown: NSEvent.pressedMouseButtons != 0)
        else { return }
        if input == .triggerDown, IsSecureEventInputEnabled() { input = .otherModifier }
        let start = detector.gestureStart
        emit(detector.handle(input, at: event.timestamp, allowsDoubleTap: allowsDoubleTap()), gestureStart: start)
        arm()
    }

    private func fire() {
        timer = nil
        let start = detector.gestureStart
        emit(detector.tick(at: ProcessInfo.processInfo.systemUptime), gestureStart: start)
        arm()
    }

    private func emit(_ output: TapDetector.Output?, gestureStart: TimeInterval?) {
        guard let output else { return }
        // Hiding a hint is always allowed.
        if output == .holdCancelled { onOutput(output); return }
        if IsSecureEventInputEnabled() || interrupted(since: gestureStart) {
            detector.reset()
            if output == .holdReleased { onOutput(.holdCancelled) }  // a hint may be showing
            return
        }
        onOutput(output)
    }

    private func interrupted(since start: TimeInterval?) -> Bool {
        guard let start else { return false }
        let age = { (type: CGEventType) in CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: type) }
        return GestureGuard.interrupted(
            lastKeyDownAge: age(.keyDown),
            lastMouseDownAge: min(age(.leftMouseDown), age(.rightMouseDown), age(.otherMouseDown)),
            gestureDuration: ProcessInfo.processInfo.systemUptime - start)
    }

    /// One-shot timer at the detector's next deadline (event timestamps use the system uptime clock).
    private func arm() {
        disarm()
        guard let deadline = detector.nextDeadline else { return }
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func disarm() {
        timer?.invalidate()
        timer = nil
    }
}
