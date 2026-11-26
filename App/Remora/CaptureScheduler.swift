import AppKit
import Capture
import CoreGraphics
import os

/// Decides when to capture and hands ticks to the `CaptureEngine`.
///
/// Triggers: frontmost-app activation (immediate), AX focused-window / title / value changes
/// on the frontmost app (debounced 1.5 s), and a 5 s timer. Every trigger goes through
/// `ActivityGate` (idle, screen lock, sleep) and a `TickCoalescer`, so a tick that is still
/// running swallows new triggers instead of stacking behind them. Ticks run as tasks on the
/// engine actor; the main actor only does bookkeeping.
///
/// The clipboard is polled every second, and each poll also samples the frontmost context.
/// A new copy is stored only if `ClipboardAttribution` confirms the context did not change
/// since the previous poll: same sampled identity, and no app activation, focused-window
/// change or title change in between (fail closed: a copy made just before a switch is
/// dropped rather than attributed to the wrong, possibly non-excluded, app/window/tab).
/// Copies are also dropped while the frontmost app's AX observer does not cover both
/// focused-window and title changes (window/tab switches would go unseen), and attaching the
/// observer counts as a context switch (switches before it were unseen).
///
/// While paused (`isPaused`), ticks are not requested (no AX read) and clipboard polls neither
/// read the pasteboard nor sample the frontmost context: the watcher's baseline just moves to
/// the current change count, so a copy made during the pause is never read, even after resuming.
///
/// The pasteboard is read off the main actor, on one serial queue (a large copied string is
/// transferred over IPC by `string(forType:)`); `NSPasteboard` is not a view/UI object and is
/// only ever touched from that queue for reads, never concurrently.
///
/// Logs (subsystem `dev.remora`, category `capture`) carry outcome kinds only, never text.
@MainActor
final class CaptureScheduler {
    /// Window events for the optional badge. Moved/resized never tick, debounce or attribute.
    enum WindowEvent { case appActivated, focusedWindowChanged, movedOrResized }

    private static let tickInterval: TimeInterval = 5
    private static let clipboardInterval: TimeInterval = 1
    private static let clipboardAttributionWindow: Duration = .seconds(1)
    private static let axDebounce: Duration = .milliseconds(1_500)
    private static let axNotifications = [
        kAXFocusedWindowChangedNotification,
        kAXTitleChangedNotification,
        kAXValueChangedNotification,
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
    ]
    /// Notifications that must be registered for clipboard copies to be attributable.
    private static let switchNotifications: Set<String> = [
        kAXFocusedWindowChangedNotification,
        kAXTitleChangedNotification,
    ]

    /// Cached pause state from the app (re-read on pause/resume, expiry and every 2 s). Fails
    /// closed until wired. The engine re-checks the stored pause before every write.
    var isPaused: @MainActor () -> Bool = { true }
    /// Receives AX window events (activation, focus change, move/resize), for the badge.
    var onWindowEvent: @MainActor (WindowEvent) -> Void = { _ in }
    /// Receives every completed context poll (nil included), for the capture indicator.
    var onContextSample: @MainActor (FrontmostWindowReader.ContextSample?) -> Void = { _ in }
    /// App, window and title changes also invalidate eligibility for a dictation upload.
    var onContextSwitch: @MainActor () -> Void = {}

    private let engine: CaptureEngine
    private let reader: FrontmostWindowReader
    private let pasteboard: any PasteboardReading
    private let logger = Logger(subsystem: "dev.remora", category: "capture")

    private var running = false
    private var coalescer = TickCoalescer()
    private var attribution = ClipboardAttribution(pollInterval: clipboardAttributionWindow)
    private var clipboardPollInFlight = false
    /// Bumped on every start/stop so a clipboard sample from a previous run is ignored.
    private var clipboardGeneration = 0
    var onSessionInactive: @MainActor () -> Void = {}
    var sessionAvailable: Bool { !screenLocked && !asleep }
    private var screenLocked = false
    private var asleep = false

    private var tickTimer: Timer?
    private var clipboardTimer: Timer?
    private var clipboard: ClipboardWatcher?
    private var debounce: Task<Void, Never>?
    private var notificationTokens: [(center: NotificationCenter, token: any NSObjectProtocol)] = []
    private var axObserver: AXNotificationObserver?
    /// Bumped on every activation so a late AX registration for a previous app is dropped.
    private var observedGeneration = 0

    init(engine: CaptureEngine, reader: FrontmostWindowReader,
         pasteboard: any PasteboardReading = SystemPasteboard()) {
        self.engine = engine
        self.reader = reader
        self.pasteboard = pasteboard
    }

    func start() {
        guard !running else { return }
        running = true
        // Lock/sleep notifications are not observed while stopped: start from a clean slate.
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        screenLocked = session == nil || session?["CGSSessionScreenIsLocked"] as? Bool == true
        asleep = false
        attribution = ClipboardAttribution(pollInterval: Self.clipboardAttributionWindow)
        clipboardGeneration += 1
        clipboardPollInFlight = false
        observeSystemNotifications()

        // Baseline taken now: whatever was copied before capture started is not stored.
        // Copies are consumed through `poll()`'s return value (see `pollClipboard`).
        clipboard = ClipboardWatcher(pasteboard: pasteboard, onText: { _ in })

        tickTimer = repeatingTimer(Self.tickInterval) { $0.requestTick() }
        clipboardTimer = repeatingTimer(Self.clipboardInterval) { $0.pollClipboard() }
        frontmostAppChanged()
    }

    func stop() {
        guard running else { return }
        running = false
        tickTimer?.invalidate()
        clipboardTimer?.invalidate()
        tickTimer = nil
        clipboardTimer = nil
        clipboard = nil
        clipboardGeneration += 1  // an in-flight clipboard sample must not store after stop
        debounce?.cancel()
        debounce = nil
        for (center, token) in notificationTokens { center.removeObserver(token) }
        notificationTokens = []
        observedGeneration += 1
        axObserver = nil
    }

    // MARK: - Triggers

    private func requestTick() {
        guard running, !isPaused(),
              ActivityGate.shouldTick(idleSeconds: SystemSignals.idleSeconds(),
                                      screenLocked: screenLocked, asleep: asleep),
              coalescer.begin() else { return }
        Task { [weak self, engine] in
            let outcome = await engine.tick()
            self?.tickFinished(outcome)
        }
    }

    private func tickFinished(_ outcome: CaptureOutcome) {
        switch coalescer.finish(outcome) {
        case .timeoutStreak(let count):
            logger.error("capture timed out \(count, privacy: .public) times in a row; frontmost app may be hung")
        case .failed:
            logger.error("capture tick failed")
        case nil:
            break
        }
    }

    private func pollClipboard() {
        guard running, !screenLocked, !asleep, let clipboard else { return }
        if isPaused() {
            // Never read the pasteboard or the frontmost context while paused. Attribution
            // restarts, so the first copy after resuming (no previous sample) is dropped.
            clipboard.consumeWithoutReading()
            attribution = ClipboardAttribution(pollInterval: Self.clipboardAttributionWindow)
            return
        }
        guard !clipboardPollInFlight else { return }
        clipboardPollInFlight = true
        let generation = clipboardGeneration
        Task { [weak self, reader] in
            let (copied, pasteboardReadAt) = await Self.readPasteboard(clipboard)
            // Sampled on every poll (not only on copies): the previous sample is what a copy
            // is checked against.
            let sample = await reader.readContext()
            self?.clipboardSampled(sample, copied: copied, pasteboardReadAt: pasteboardReadAt,
                                   generation: generation)
        }
    }

    /// Polls the watcher on the pasteboard queue. Returns the new copy (if any) and when the
    /// pasteboard was checked.
    nonisolated private static func readPasteboard(_ watcher: ClipboardWatcher) async
        -> (String?, ContinuousClock.Instant) {
        await withCheckedContinuation { continuation in
            SystemPasteboard.queue.async {
                let at = ContinuousClock.now
                continuation.resume(returning: (watcher.poll(), at))
            }
        }
    }

    private func clipboardSampled(_ sample: FrontmostWindowReader.ContextSample?, copied: String?,
                                  pasteboardReadAt: ContinuousClock.Instant, generation: Int) {
        guard generation == clipboardGeneration else { return }
        onContextSample(sample)
        clipboardPollInFlight = false
        let attributable = attribution.completePoll(
            identity: sample?.identity, pasteboardReadAt: pasteboardReadAt, now: .now)
        guard let copied else { return }
        // Unknown context (Remora frontmost, app unresponsive), a context switch around the
        // copy, or no AX observer to report switches: exclusions cannot be evaluated
        // reliably, so the copy is consumed, not stored.
        guard attributable, observesContextSwitches, let context = sample?.context else {
            logger.debug("clipboard copy dropped: context unknown or changed")
            return
        }
        Task { [engine, logger] in
            let outcome = await engine.storeClipboard(text: copied, context: context)
            if outcome == .failed { logger.error("clipboard capture failed") }
        }
    }

    var observesContextSwitches: Bool {
        axObserver.map { Self.switchNotifications.isSubset(of: $0.registered) } ?? false
    }

    private func axNotified(_ name: String) {
        guard running else { return }
        if name == kAXWindowMovedNotification || name == kAXWindowResizedNotification {
            onWindowEvent(.movedOrResized)
            return
        }
        if name == kAXFocusedWindowChangedNotification { onWindowEvent(.focusedWindowChanged) }
        if let event = ContextEvent(axNotification: name) {
            attribution.record(event, at: .now)
            if event != .valueChanged { onContextSwitch() }
        }
        debounce?.cancel()
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: Self.axDebounce) } catch { return }
            self?.requestTick()
        }
    }

    private func frontmostAppChanged() {
        onWindowEvent(.appActivated)
        onContextSwitch()
        attribution.record(.appActivated, at: .now)
        observedGeneration += 1
        axObserver = nil
        requestTick()

        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        let generation = observedGeneration
        let pid = app.processIdentifier
        Task { [weak self] in
            let observer = await AXNotificationObserver.observe(
                pid: pid, notifications: Self.axNotifications) { [weak self] in self?.axNotified($0) }
            // A stale registration is released here, which removes its run-loop source.
            guard let self, self.running, generation == self.observedGeneration else { return }
            self.axObserver = observer
            // Same-app switches between activation and now went unseen.
            if observer != nil { self.attribution.record(.observerAttached, at: .now) }
        }
    }

    // MARK: - System state

    private func observeSystemNotifications() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { $0.frontmostAppChanged() }
        observe(workspace, NSWorkspace.willSleepNotification) { $0.asleep = true; $0.onSessionInactive() }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.asleep = false; $0.requestTick() }

        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.screenLocked = true; $0.onSessionInactive() }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) {
            $0.screenLocked = false
            $0.requestTick()
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ action: @escaping @MainActor (CaptureScheduler) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        notificationTokens.append((center, token))
    }

    private func repeatingTimer(_ interval: TimeInterval,
                                _ action: @escaping @MainActor (CaptureScheduler) -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        timer.tolerance = interval / 10
        // Common modes: keep firing while the menu-bar menu is open.
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
