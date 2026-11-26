import Foundation

/// How careful an action is: `reversible` ones run (with an undo) unless the turn read untrusted
/// data; `confirm` ones always ask first (Task 4 policy).
public enum ActionRisk: Sendable, Equatable {
    case reversible, confirm
}

/// An action the chat wants to take, shown to the user for confirmation.
public struct ActionProposal: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var tool: String
    /// One plain sentence, e.g. "Never capture the site example.com".
    public var summary: String
    public var risk: ActionRisk
    /// The turn read untrusted data (captured text) before proposing this.
    public var afterUntrustedRead: Bool

    public init(id: UUID = UUID(), tool: String, summary: String, risk: ActionRisk, afterUntrustedRead: Bool) {
        self.id = id; self.tool = tool; self.summary = summary; self.risk = risk
        self.afterUntrustedRead = afterUntrustedRead
    }
}

/// What undoing an action takes. Never removes an exclusion the user made: `removeExclusion` only
/// undoes one the chat just added.
public enum UndoToken: Codable, Sendable, Equatable {
    case removeExclusion(String)
    /// Undo puts `previous` back only while the pause is still `applied` (nil: resumed).
    case restorePause(previous: Date?, applied: Date?)
    case cancelReminder(Int64)
    case reactivateReminder(Int64)
    /// Undo puts `previous` back only while the setting still reads `applied`.
    case restoreSetting(name: String, previous: String, applied: String)
}

/// The result of an action, stored with the chat turn.
public struct ActionReceipt: Codable, Sendable, Equatable {
    public var summary: String
    public var undo: UndoToken?
    /// The `DataGeneration` the action wrote under: pass it to `ActionTools.perform` so an undo
    /// after a delete-all is refused (nil for receipts stored before it existed).
    public var generation: Int?

    public init(summary: String, undo: UndoToken?, generation: Int? = nil) {
        self.summary = summary; self.undo = undo; self.generation = generation
    }
}

/// What a tool is, for the confirmation policy.
public enum ToolKind: Sendable, Equatable {
    /// Returns captured or model-derived text, which anyone may have written: taints the turn.
    case untrustedRead
    /// Returns only Remora's own data (usage, time totals, the built-in guide).
    case trustedRead
    case action(ActionRisk)
}

/// What a tool run gets from the chat agent.
public struct ToolContext: Sendable {
    public var now: Date
    public var calendar: Calendar
    /// An untrusted read already happened in this turn.
    public var turnTainted: Bool
    /// Asks the user; true when they accepted.
    public var confirm: @Sendable (ActionProposal) async -> Bool
    /// The `DataGeneration` read when the turn started. Action tools write under it, so an action
    /// (even one confirmed later) never writes after a delete-all that happened during the turn.
    /// nil: the tool reads it when it starts.
    public var generation: Int?

    public init(now: Date, calendar: Calendar, turnTainted: Bool, confirm: @escaping @Sendable (ActionProposal) async -> Bool,
                generation: Int? = nil) {
        self.now = now; self.calendar = calendar; self.turnTainted = turnTainted; self.confirm = confirm
        self.generation = generation
    }
}

/// One tool call's result. `output` goes back to the model as the function call output.
public struct ToolRun: Sendable, Equatable {
    /// At most `ChatToolbox.outputLimit` characters plus the truncation suffix.
    public var recordingIDs: Set<UUID> = []
    public var output: String
    public var isError: Bool
    public var receipt: ActionReceipt?
    /// For actions: whether the user was asked and accepted (nil when not asked).
    public var confirmed: Bool?

    public init(output: String, isError: Bool, receipt: ActionReceipt? = nil, confirmed: Bool? = nil) {
        self.output = output; self.isError = isError; self.receipt = receipt; self.confirmed = confirmed
    }

    public static func error(_ message: String) -> ToolRun { ToolRun(output: message, isError: true) }
}
