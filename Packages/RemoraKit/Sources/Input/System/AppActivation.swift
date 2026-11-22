import AppKit

public struct AppActivation: AppActivating {
    public init() {}

    public func frontmostPID() -> pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    /// Yields activation to the app (cooperative activation) and waits up to 500 ms for it to be
    /// frontmost.
    public func activate(pid: pid_t) async -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        if frontmostPID() == pid { return true }
        await MainActor.run {
            NSApplication.shared.yieldActivation(to: app)
            _ = app.activate(from: .current, options: [])
        }
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(500)
        while clock.now < deadline {
            if frontmostPID() == pid { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return frontmostPID() == pid
    }
}
