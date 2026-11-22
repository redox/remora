import Foundation
import GRDB
import Storage

/// What the chat panel shows for stored turns: error copy, tool activity, inbox labels and cost
/// details. Pure, so the app's views stay glue. Copy is English (pinned).
public enum ChatPresentation {
    public struct ErrorCopy: Sendable, Equatable {
        public enum Action: Sendable, Equatable { case manageUsage, openSettings }
        public var text: String
        public var action: Action?
        /// "Stopped." is set in italics.
        public var italic: Bool

        public init(text: String, action: Action?, italic: Bool = false) {
            self.text = text; self.action = action; self.italic = italic
        }
    }

    public static let emptyPrompt = "Ask about anything you've seen, or say “remind me…”"
    public static let starters = ["What did I do yesterday?", "What am I waiting on?", "What routines have you noticed?"]

    /// The line under a failed or cancelled assistant turn, by its stored error code.
    public static func errorCopy(_ t: ChatTurn) -> ErrorCopy? {
        guard t.role == .assistant else { return nil }
        switch t.status {
        case .complete, .pending: return nil
        case .cancelled: return ErrorCopy(text: "Stopped.", action: nil, italic: true)
        case .failed: break
        }
        switch t.error ?? "" {
        case "usage_limit": return ErrorCopy(text: "Usage limit reached.", action: .manageUsage)
        case "sign_in": return ErrorCopy(text: "Sign in with ChatGPT to chat.", action: .openSettings)
        case "unavailable", "temporarily_unavailable":
            return ErrorCopy(text: unavailable, action: nil)
        case let c where c.hasPrefix("transport_"):
            return ErrorCopy(text: unavailable, action: nil)
        case ChatStore.interruptedError: return ErrorCopy(text: "Interrupted.", action: nil)
        // Addendum B4: `.notEligible` reads as the plan-unavailable notice.
        case "not_eligible": return ErrorCopy(text: "ChatGPT plan usage isn't available for this account.", action: .openSettings)
        default: return ErrorCopy(text: "Something went wrong.", action: nil)
        }
    }

    private static let unavailable = "ChatGPT is unavailable right now. Try again."

    /// The line shown while a tool runs.
    public static func activity(tool: String, kind: ToolKind?) -> String {
        if tool == "get_remora_guide" { return "Checking the guide…" }
        switch kind {
        case .untrustedRead?, .trustedRead?: return "Looking at your memory…"
        case .action?, nil: return "Working…"
        }
    }

    public static func label(_ k: InboxKind) -> String {
        switch k {
        case .morningBrief: "Morning brief"
        case .eveningWrap: "Evening wrap-up"
        case .nudge: "Nudge"
        case .reminder: "Reminder"
        }
    }

    /// "est. $x" (4 decimals under a cent), or "—" for an unpriced model.
    public static func cost(_ usd: Double?) -> String {
        guard let usd else { return "—" }
        let format = usd > 0 && usd < 0.01 ? "%.4f" : "%.2f"
        return "est. $" + String(format: format, locale: Locale(identifier: "en_US_POSIX"), usd)
    }

    public struct Totals: Sendable, Equatable {
        public var inputTokens: Int
        public var outputTokens: Int
        /// The priced calls' sum; nil when none is priced.
        public var estCostUSD: Double?
        public var someUnpriced: Bool

        public init(inputTokens: Int, outputTokens: Int, estCostUSD: Double?, someUnpriced: Bool) {
            self.inputTokens = inputTokens; self.outputTokens = outputTokens
            self.estCostUSD = estCostUSD; self.someUnpriced = someUnpriced
        }
    }

    public static func totals(_ calls: [GeneratedBy]) -> Totals {
        let priced = calls.compactMap(\.estCostUSD)
        return Totals(inputTokens: calls.reduce(0) { $0 + $1.inputTokens },
                      outputTokens: calls.reduce(0) { $0 + $1.outputTokens },
                      estCostUSD: priced.isEmpty ? nil : priced.reduce(0, +),
                      someUnpriced: priced.count < calls.count)
    }

    /// One send at a time: the composer sends only text, only between turns, and not while the
    /// history is being cleared.
    public static func canSend(draft: String, isStreaming: Bool, clearing: Bool = false) -> Bool {
        !isStreaming && !clearing && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public enum ReturnKeyAction: Sendable, Equatable {
        /// Send the draft.
        case send
        /// Insert a newline at the caret.
        case newline
        /// Handled, nothing happens.
        case swallow
        /// Not ours: the input method commits its marked text.
        case passThrough
    }

    /// Return in the composer. It never answers a confirmation card (only a click on Allow does),
    /// and while a card waits it doesn't send either.
    public static func returnKey(shift: Bool, composing: Bool, cardPending: Bool) -> ReturnKeyAction {
        if composing { return .passThrough }
        if shift { return .newline }
        return cardPending ? .swallow : .send
    }

    /// Esc belongs to the input method while it composes (it cancels the marked text).
    public static func barTakesEscape(composing: Bool) -> Bool { !composing }

    /// The panel height the card's summary can't use: header, composer, the card's label, footer
    /// and buttons, and paddings (an estimate in body-font lines, measured at 13 and 19.5 pt).
    public static func cardReservedHeight(fontSize: Double) -> Double { fontSize * 12.5 }

    /// The card summary's height cap: at most 180 pt and 35 % of the panel, and no more than the
    /// chrome leaves, so Allow, Don't allow and the composer stay visible at the minimum size;
    /// never under one line (it scrolls).
    public static func cardSummaryMaxHeight(panelHeight: Double, fontSize: Double) -> Double {
        let cap = min(180, panelHeight * 0.35)
        let room = panelHeight - cardReservedHeight(fontSize: fontSize)
        return max(fontSize * 1.4, min(cap, room))
    }

    /// The receipts stored with a turn (summaries only: undo needs the live receipt).
    public static func storedReceipts(_ t: ChatTurn) -> [String] {
        t.tools.compactMap { $0.ok ? $0.receipt : nil }
    }

    /// The inbox kind of every turn that delivers an inbox message.
    public static func inboxKinds(_ turns: [ChatTurn], db: AppDatabase) throws -> [Int64: InboxKind] {
        guard turns.contains(where: { $0.inboxID != nil }) else { return [:] }
        return try db.reader.read { d in try ChatAgent.inboxKinds(turns, in: d) }
    }
}
