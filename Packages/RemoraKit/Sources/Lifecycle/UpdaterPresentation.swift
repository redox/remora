import Foundation

/// What the updater is doing, as the menu and Settings show it.
public enum UpdaterPhase: Equatable, Sendable {
    /// No updater exists (`UpdateConfiguration.evaluate` was not `.ready`).
    case disabled(UpdatesDisabledReason)
    case idle
    /// Found by a scheduled check while automatic installs are off; Sparkle's window waits for the user.
    case updateAvailable(version: String)
    /// Downloaded and waiting for `UpdateInstallPolicy`, or for "Restart to Update".
    case readyToInstall(version: String)
}

/// Pinned copy for Settings › General › Updates and the menu bar.
public enum UpdateCopy {
    public static let automaticToggle = "Install updates automatically"
    public static let checkForUpdates = "Check for Updates…"
    public static let caption = "Remora checks GitHub for a new version about once an hour, downloads it, and installs it when you're away from the keyboard, then restarts."

    public static func versionLine(short: String, build: String) -> String { "Version \(short) (\(build))" }

    public static func restartToUpdate(version: String) -> String { "Restart to Update to Remora \(version)" }

    public static func disabledCaption(_ reason: UpdatesDisabledReason) -> String {
        switch reason {
        case .debugBuild: "Updates are off in development builds."
        case .missingFeed, .invalidFeed, .missingKey, .invalidKey: "Updates aren't set up in this build."
        case .notInstalled: "Updates work once Remora is in Applications."
        }
    }
}

/// The menu bar's update item; nil (hidden) while updates are off.
public struct UpdateMenuItem: Equatable, Sendable {
    public enum Action: Equatable, Sendable { case check, installNow }

    public let title: String
    public let action: Action
    public let enabled: Bool

    public init(title: String, action: Action, enabled: Bool) {
        self.title = title
        self.action = action
        self.enabled = enabled
    }

    /// `busy` is `isBusyForUpdate`: "Restart to Update" waits while Remora is in the middle of something.
    public static func make(phase: UpdaterPhase, canCheck: Bool, busy: Bool = false) -> UpdateMenuItem? {
        switch phase {
        case .disabled: nil
        case .idle: UpdateMenuItem(title: UpdateCopy.checkForUpdates, action: .check, enabled: canCheck)
        // Sparkle can report `canCheckForUpdates` false while a reminder holds the update; checking brings it up.
        case .updateAvailable: UpdateMenuItem(title: UpdateCopy.checkForUpdates, action: .check, enabled: true)
        case .readyToInstall(let version):
            UpdateMenuItem(title: UpdateCopy.restartToUpdate(version: version), action: .installNow, enabled: !busy)
        }
    }
}

/// A downloaded update waiting to be installed.
public struct PendingInstall: Equatable, Sendable {
    public let readySince: Date

    public init(readySince: Date) { self.readySince = readySince }

    /// A newer update superseding a pending one keeps the earlier time, so the one-day fallback isn't reset.
    public static func next(after previous: PendingInstall?, now: Date) -> PendingInstall {
        PendingInstall(readySince: min(previous?.readySince ?? now, now))
    }

    /// `UpdateInstallPolicy` with the time waited so far (never negative, so a clock set back can't force it).
    public func shouldInstall(now: Date, busy: Bool, idleSeconds: TimeInterval) -> Bool {
        UpdateInstallPolicy.shouldInstallNow(busy: busy, idleSeconds: idleSeconds,
                                             readyFor: max(0, now.timeIntervalSince(readySince)))
    }
}
