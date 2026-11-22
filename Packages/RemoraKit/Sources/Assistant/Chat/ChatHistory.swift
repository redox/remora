import Foundation
import LLM
import Storage

/// What earlier turns the model sees: user and assistant **text only** (old tool calls and outputs
/// are never replayed), newest first up to a token budget, then put back in chronological order.
public struct ChatHistory {
    /// The turns `input` replays, oldest first: unfolded, not pending, non-empty text, the newest
    /// contiguous run within `budgetTokens`.
    public static func kept(turns: [ChatTurn], budgetTokens: Int, inboxKinds: [Int64: InboxKind] = [:]) -> [ChatTurn] {
        var kept: [ChatTurn] = []
        var used = 0
        for t in turns.reversed() where !t.folded && t.status != .pending {
            let text = replayText(t, inboxKinds: inboxKinds)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let cost = TokenEstimate.count(text)
            if used + cost > budgetTokens { break }
            used += cost
            kept.append(t)
        }
        return kept.reversed()
    }

    /// `earlier` is the latest summary of the folded turns, for `<earlier_conversation>`.
    public static func input(turns: [ChatTurn], summary: ChatSummary?, budgetTokens: Int,
                             inboxKinds: [Int64: InboxKind] = [:]) -> (items: [InputItem], earlier: String?) {
        let items: [InputItem] = kept(turns: turns, budgetTokens: budgetTokens, inboxKinds: inboxKinds).map {
            let text = replayText($0, inboxKinds: inboxKinds)
            return $0.role == .user ? .user(text) : .assistant(text)
        }
        let earlier = summary.map(\.body).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        return (items, earlier)
    }

    /// An assistant turn that delivered an inbox message says what it was ("[Morning brief] …").
    static func replayText(_ t: ChatTurn, inboxKinds: [Int64: InboxKind]) -> String {
        guard t.role == .assistant, let id = t.inboxID, !t.text.isEmpty else { return t.text }
        return "[\(label(inboxKinds[id]))] " + t.text
    }

    static func label(_ kind: InboxKind?) -> String {
        switch kind {
        case .morningBrief: "Morning brief"
        case .eveningWrap: "Evening wrap"
        case .nudge: "Nudge"
        case .reminder: "Reminder"
        case nil: "Remora message"
        }
    }
}
