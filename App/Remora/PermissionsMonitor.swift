import AppKit
import ApplicationServices
import Dictation
import Observation

/// Tracks the Accessibility grant and the microphone authorization. Polls both every 2 s because
/// macOS posts no notification when the user flips a switch in System Settings. Reading the
/// microphone status never prompts; only `requestMicrophone()` does.
@MainActor @Observable
final class PermissionsMonitor {
    private(set) var accessibilityGranted: Bool
    private(set) var microphone: MicrophoneStatus
    @ObservationIgnored private let microphonePermission: any MicrophonePermission = SystemMicrophonePermission()
    /// Called on the main actor whenever the grant changes (not for the initial value).
    @ObservationIgnored var onChange: ((Bool) -> Void)?
    /// Called on every poll (2 s), for cheap periodic refreshes.
    @ObservationIgnored var onTick: (() -> Void)?
    @ObservationIgnored private var timer: Timer?

    init() {
        accessibilityGranted = AXIsProcessTrusted()
        microphone = microphonePermission.status()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func poll() {
        refreshMicrophone()
        onTick?()
        let granted = AXIsProcessTrusted()
        guard granted != accessibilityGranted else { return }
        accessibilityGranted = granted
        onChange?(granted)
    }

    /// Shows the system prompt (which links to System Settings) if not yet trusted.
    func requestAccessibility() {
        // The literal value of kAXTrustedCheckOptionPrompt (a non-Sendable global in Swift 6).
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func refreshMicrophone() {
        let status = microphonePermission.status()
        if status != microphone { microphone = status }
    }

    /// Shows the system microphone prompt (only while the status is not determined), then re-reads it.
    func requestMicrophone() async {
        _ = await microphonePermission.request()
        refreshMicrophone()
    }

    func openMicrophoneSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
    }

    func openAccessibilitySettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}
