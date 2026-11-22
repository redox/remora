import AppKit
import Foundation
import Lifecycle
import Observation
import os
@preconcurrency import Sparkle

/// Sparkle, Goldfish-style: hourly checks, silent download, then install and restart once the user
/// is away (`UpdateInstallPolicy`), never while Remora is busy.
///
/// **No updater exists unless `UpdateConfiguration.evaluate` returned `.ready`.** Info.plist ships
/// `SUEnableAutomaticChecks` and `SUAutomaticallyUpdate` = true, so creating one with the placeholder
/// feed or an empty key would start polling. Debug builds and unconfigured builds stay `.disabled`.
///
/// Logs versions, decisions and `NSError` domain/code only.
@MainActor @Observable
final class UpdaterController: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    typealias State = UpdaterPhase

    static let installCheckInterval: TimeInterval = 60

    private(set) var state: State
    /// Mirrors Sparkle's `canCheckForUpdates` (KVO); false while disabled or a check runs.
    private(set) var canCheckForUpdates = false
    /// Mirrors Sparkle's `automaticallyDownloadsUpdates` so SwiftUI sees changes.
    private var automaticallyInstallsValue = false

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?
    @ObservationIgnored private var pending: PendingInstall?
    @ObservationIgnored private var installBlock: InstallHandler?
    @ObservationIgnored private var installTimer: Timer?
    @ObservationIgnored private let isBusy: @MainActor () -> Bool
    @ObservationIgnored private let idleSeconds: @MainActor () -> TimeInterval
    @ObservationIgnored private static let log = Logger(subsystem: "dev.remora", category: "updates")

    init(configuration: UpdateConfiguration, isBusy: @escaping @MainActor () -> Bool,
         idleSeconds: @escaping @MainActor () -> TimeInterval) {
        self.isBusy = isBusy
        self.idleSeconds = idleSeconds
        switch configuration {
        case .disabled(let reason):
            state = .disabled(reason)
            super.init()
            Self.log.info("updates disabled: \(String(describing: reason), privacy: .public)")
        case .ready:
            state = .idle
            super.init()
            // Only here: the feed and key passed `evaluate`. Sparkle reads them from Info.plist.
            let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self,
                                                          userDriverDelegate: self)
            self.controller = controller
            let updater = controller.updater
            automaticallyInstallsValue = updater.automaticallyDownloadsUpdates
            canCheckObservation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
                [weak self] updater, _ in
                // Sparkle changes this on the main thread.
                MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
            }
            Self.log.info("updater started")
        }
    }

    /// The "Install updates automatically" toggle (Sparkle's `automaticallyDownloadsUpdates`).
    /// Always false, and not settable, while updates are off.
    var automaticallyInstalls: Bool {
        get { controller == nil ? false : automaticallyInstallsValue }
        set {
            guard let updater = controller?.updater else { return }
            updater.automaticallyDownloadsUpdates = newValue
            automaticallyInstallsValue = updater.automaticallyDownloadsUpdates
            Self.log.info("automatic installs: \(newValue, privacy: .public)")
        }
    }

    func menuItem(busy: Bool) -> UpdateMenuItem? {
        UpdateMenuItem.make(phase: state, canCheck: canCheckForUpdates, busy: busy)
    }

    /// Fail closed: Debug, an unconfigured build, or a copy outside Applications (or translocated) gets no updater.
    static func configuration() -> UpdateConfiguration {
        #if DEBUG
        let isDebugBuild = true
        #else
        let isDebugBuild = false
        #endif
        let info = Bundle.main.infoDictionary
        let location = InstallLocation.classify(bundlePath: Bundle.main.bundleURL.resolvingSymlinksInPath().path,
                                                homeDirectory: NSHomeDirectory())
        return UpdateConfiguration.evaluate(feedURL: info?["SUFeedURL"] as? String,
                                            publicKey: info?["SUPublicEDKey"] as? String,
                                            isDebugBuild: isDebugBuild, isInstalled: location.isInstalled)
    }

    /// "Check for Updates…": Sparkle's own window (also shows an update a gentle reminder is holding).
    func checkForUpdates() {
        guard let controller else { return }
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    /// "Restart to Update to Remora x.y.z": an explicit user action, so it skips the idle policy,
    /// but never restarts Remora while it is busy (the menu item is disabled then too).
    func installNow() {
        guard let handler = installBlock else { return }
        guard !isBusy() else {
            Self.log.info("install deferred: busy")
            return
        }
        install(handler, reason: "user")
    }

    // MARK: - Install when idle

    private func install(_ handler: InstallHandler, reason: StaticString) {
        installTimer?.invalidate()
        installTimer = nil
        installBlock = nil
        pending = nil
        Self.log.info("installing update: \(reason, privacy: .public)")
        handler.run()
    }

    private func resetToIdle() {
        installTimer?.invalidate()
        installTimer = nil
        installBlock = nil
        pending = nil
        state = .idle
    }

    private func startInstallTimer() {
        installTimer?.invalidate()
        let timer = Timer(timeInterval: Self.installCheckInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.installIfAllowed() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        installTimer = timer
    }

    private func installIfAllowed() {
        guard let pending, let handler = installBlock else { return }
        guard pending.shouldInstall(now: .now, busy: isBusy(), idleSeconds: idleSeconds()) else { return }
        install(handler, reason: "policy")
    }

    // MARK: - SPUUpdaterDelegate

    /// Sparkle would install on quit, which a menu-bar app rarely does: keep the block and install
    /// when `UpdateInstallPolicy` allows (checked every 60 s), or on "Restart to Update".
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        let handler = InstallHandler(run: immediateInstallHandler)
        return MainActor.assumeIsolated {
            installBlock = handler
            // A newer update superseding a pending one keeps the earlier time (the one-day fallback isn't reset).
            pending = PendingInstall.next(after: pending, now: .now)
            state = .readyToInstall(version: version)
            Self.log.info("update ready: \(version, privacy: .public)")
            startInstallTimer()
            return true
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        MainActor.assumeIsolated { Self.log.info("update found: \(version, privacy: .public)") }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        MainActor.assumeIsolated {
            if case .updateAvailable = state { state = .idle }
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let ns = error as NSError
        let domain = ns.domain, code = ns.code
        MainActor.assumeIsolated {
            Self.log.error("update aborted: \(domain, privacy: .public) \(code, privacy: .public)")
            // Also how a failed install ends: drop the stale install block so the menu offers a fresh check.
            resetToIdle()
        }
    }

    // MARK: - SPUStandardUserDriverDelegate (gentle reminders)

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// A scheduled check never pops a window on its own: the menu holds it instead.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                               forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        let version = update.displayVersionString
        let userInitiated = state.userInitiated
        MainActor.assumeIsolated {
            guard !handleShowingUpdate, !userInitiated else { return }
            if case .readyToInstall = self.state { return }
            self.state = .updateAvailable(version: version)
            Self.log.info("update available (reminder): \(version, privacy: .public)")
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated {
            if case .updateAvailable = state { state = .idle }
        }
    }
}

/// Sparkle's immediate-installation block. Sparkle hands it over on the main thread and it is only
/// ever called there (the timer and the menu are main-actor), so crossing into `assumeIsolated` is safe.
private struct InstallHandler: @unchecked Sendable {
    let run: () -> Void
}
