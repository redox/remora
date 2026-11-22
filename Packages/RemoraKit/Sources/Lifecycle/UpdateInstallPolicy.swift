import Foundation

/// When a downloaded update may be installed and Remora relaunched.
/// Never while busy (dictating, rewriting, deleting, a memory job); otherwise after two idle minutes,
/// or regardless of idleness once the update has waited a day.
public enum UpdateInstallPolicy {
    public static let idleThreshold: TimeInterval = 120
    public static let forceAfter: TimeInterval = 86_400

    public static func shouldInstallNow(busy: Bool, idleSeconds: TimeInterval, readyFor: TimeInterval) -> Bool {
        !busy && (idleSeconds >= idleThreshold || readyFor >= forceAfter)
    }
}
