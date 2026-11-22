import Foundation

/// When the chat must ask before acting. A `confirm` action always asks. Any action asks once
/// the turn has read untrusted data (captured or model-derived text), so text on screen can never
/// make Remora act on its own ("add an exclusion", "forget these snapshots"…).
public enum ActionPolicy {
    public static func needsConfirmation(_ risk: ActionRisk, turnTainted: Bool) -> Bool {
        risk == .confirm || turnTainted
    }
}

/// What an action changed, so the app can refresh the matching state (capture rules, pause
/// indicator, reminder timer, settings panes…).
public enum ActionChange: Sendable, Equatable {
    case exclusions, pause, reminders, identity, wiki, snapshots, routines
    /// A `SettingRegistry` entry, by name.
    case setting(String)
}

/// Told after every action and undo. The app applies changes; tests record them.
public protocol ActionEffects: Sendable {
    func didChange(_ c: ActionChange) async
}
