import Foundation
import Lifecycle
import Observation
import os
import ServiceManagement

/// "Open at login" via `SMAppService.mainApp`. Registered once on first launch; afterwards the
/// user's choice (the Settings toggle) is respected. A copy outside Applications never registers, so
/// the first-launch flag stays unset until the installed copy runs.
@MainActor @Observable
final class LoginItem {
    private static let firstLaunchKey = "firstLaunchDone"
    private static let logger = Logger(subsystem: "dev.remora", category: "login-item")

    private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    private(set) var errorMessage: String?

    var isEnabled: Bool { status == .enabled }
    var needsApproval: Bool { status == .requiresApproval }

    /// Where this copy runs; only an installed copy may turn the login item on.
    var location: InstallLocation {
        InstallLocation.classify(bundlePath: Bundle.main.bundleURL.resolvingSymlinksInPath().path,
                                 homeDirectory: NSHomeDirectory())
    }

    var canEnable: Bool { LoginItemPolicy.allowsUserChange(to: true, location: location) }

    func registerOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard LoginItemPolicy.shouldRegisterOnFirstLaunch(firstLaunchDone: defaults.bool(forKey: Self.firstLaunchKey),
                                                          location: location) else { return }
        setEnabled(true)
        // Only after success, so a failed registration is retried on the next launch.
        if errorMessage == nil { defaults.set(true, forKey: Self.firstLaunchKey) }
    }

    func refresh() { status = SMAppService.mainApp.status }

    /// A user toggle: counts as the user's explicit choice, so no automatic registration later.
    /// Refused (no flag set) when turning it on from a copy outside Applications.
    func userSet(_ enabled: Bool) {
        guard LoginItemPolicy.allowsUserChange(to: enabled, location: location) else {
            Self.logger.notice("login item change refused: not installed")
            return
        }
        UserDefaults.standard.set(true, forKey: Self.firstLaunchKey)
        setEnabled(enabled)
    }

    private func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Self.logger.error("login item change failed: \(String(describing: type(of: error)), privacy: .public)")
            errorMessage = "Could not \(enabled ? "enable" : "disable") Open at login: \(error.localizedDescription)"
        }
        refresh()
    }
}
