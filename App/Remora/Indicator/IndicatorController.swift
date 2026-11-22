import AppKit
import Capture
import Indicator
import Observation
import os

/// Turns the scheduler's context samples and workspace activations into the indicator state.
///
/// No AX reads here: the scheduler's existing 1 s sample is the only context source, and
/// verdicts come from `CaptureEngine.verdict(for:)` (a small rules read, no AX). Logs carry
/// state kinds only, never names, titles or hosts.
@MainActor @Observable
final class IndicatorController {
    private(set) var state: IndicatorState = .initial
    private(set) var dot: IndicatorDot?

    /// Receives the text of the transient switch label.
    @ObservationIgnored var onAnnounce: @MainActor (String) -> Void = { _ in }
    @ObservationIgnored var onStateChange: @MainActor (IndicatorState) -> Void = { _ in }

    @ObservationIgnored private let engine: CaptureEngine
    @ObservationIgnored private let isPaused: @MainActor () -> Bool
    @ObservationIgnored private let accessibilityGranted: @MainActor () -> Bool
    @ObservationIgnored private var announcer = IndicatorAnnouncer()
    @ObservationIgnored private var frontmost: FrontmostApp?
    @ObservationIgnored private var observed: ObservedWindow?
    @ObservationIgnored private var activationGeneration = 0
    @ObservationIgnored private var sampleGeneration = 0
    /// Set by a rule reload, cleared when a verdict lands: the cached verdict must not be reused meanwhile.
    @ObservationIgnored private var verdictStale = false
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?
    @ObservationIgnored private let logger = Logger(subsystem: "dev.remora", category: "indicator")

    init(engine: CaptureEngine,
         isPaused: @escaping @MainActor () -> Bool,
         accessibilityGranted: @escaping @MainActor () -> Bool) {
        self.engine = engine
        self.isPaused = isPaused
        self.accessibilityGranted = accessibilityGranted
    }

    func start() {
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let info = app.map { AppInfo(pid: $0.processIdentifier, name: $0.localizedName, bundleID: $0.bundleIdentifier) }
            Task { @MainActor in self?.activated(info) }
        }
        let current = NSWorkspace.shared.frontmostApplication
        activated(current.map { AppInfo(pid: $0.processIdentifier, name: $0.localizedName, bundleID: $0.bundleIdentifier) })
    }

    /// Called for every completed context poll. A nil sample keeps the previous observation:
    /// the reducer's pid check handles staleness.
    func contextSampled(_ sample: FrontmostWindowReader.ContextSample?) {
        guard let sample else { return }
        if let front = frontmost, front.appVerdict == .rulesUnavailable { verdictForApp(front) }
        if let seen = observed, seen.context == sample.context,
           shouldReuseVerdict(seen.verdict, stale: verdictStale) {
            // Invalidate any older in-flight verdict so it cannot overwrite this observation.
            sampleGeneration += 1
            observed = ObservedWindow(context: seen.context, identity: sample.identity, verdict: seen.verdict)
            recompute()
            return
        }
        sampleGeneration += 1
        let generation = sampleGeneration
        Task { [engine] in
            let verdict = await engine.verdict(for: sample.context)
            guard generation == self.sampleGeneration else { return }
            self.verdictStale = false
            self.observed = ObservedWindow(context: sample.context, identity: sample.identity, verdict: verdict)
            self.recompute()
        }
    }

    /// Recomputes the state after a pause, permission or rule change.
    func refresh(reloadRules: Bool = false) {
        if reloadRules {
            verdictStale = true  // cleared when a verdict lands; samples re-fetch until then
            if let seen = observed {
                sampleGeneration += 1
                let generation = sampleGeneration
                Task { [engine] in
                    let verdict = await engine.verdict(for: seen.context)
                    guard generation == self.sampleGeneration else { return }
                    self.verdictStale = false
                    self.observed = ObservedWindow(context: seen.context, identity: seen.identity, verdict: verdict)
                    self.recompute()
                }
            }
            if let front = frontmost { verdictForApp(front) }
        }
        recompute()
    }

    // MARK: - Private

    private struct AppInfo: Sendable {
        var pid: Int32
        var name: String?
        var bundleID: String?
    }

    private func activated(_ app: AppInfo?) {
        activationGeneration += 1
        guard let app, app.bundleID != Bundle.main.bundleIdentifier else {
            frontmost = nil
            recompute()
            return
        }
        var name = AppName.normalize(app.name ?? "")
        if name.isEmpty { name = app.bundleID ?? "" }
        let front = FrontmostApp(pid: app.pid, name: name, bundleID: app.bundleID, appVerdict: nil)
        frontmost = front
        recompute()
        verdictForApp(front)
    }

    /// App-only verdict (no AX), dropped if another activation arrived meanwhile.
    private func verdictForApp(_ front: FrontmostApp) {
        let activation = activationGeneration
        Task { [engine] in
            let verdict = await engine.appVerdict(for: WindowContext(app: front.name, bundleID: front.bundleID))
            guard activation == self.activationGeneration, self.frontmost?.pid == front.pid else { return }
            self.frontmost?.appVerdict = verdict
            self.recompute()
        }
    }

    private func recompute() {
        let next = IndicatorState.reduce(IndicatorInput(
            accessibilityGranted: accessibilityGranted(), isPaused: isPaused(),
            frontmost: frontmost, observed: observed))
        let changed = next != state
        state = next
        let newDot = next.dot(previous: dot)
        if newDot != dot { dot = newDot }
        if let text = announcer.update(next) { onAnnounce(text) }
        if changed {
            logger.debug("indicator state changed: \(next.status.kind, privacy: .public)")
            onStateChange(next)
        }
    }
}
