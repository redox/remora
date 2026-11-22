import CoreGraphics
import Foundation
import IOKit.ps

/// Raw system readings for capture and background memory. The mapping to scheduler signals is
/// `SchedulerSignals.make` (Memory, unit-tested).
enum SystemSignals {
    /// Seconds since the last user input of any kind.
    ///
    /// `kCGAnyInputEventType` (~0), not `.null`: measured on macOS 26, `.null` reports the
    /// time since login (hours), which would make every gate think the user is always idle.
    static func idleSeconds() -> TimeInterval {
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    /// True on AC power. Unknown (no power-source info, e.g. a desktop Mac) counts as on power.
    static func onACPower() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return true }
        return (type as String) == kIOPMACPowerKey
    }

    /// Low Power Mode (counts as not on power for background memory).
    static var lowPower: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }
}
