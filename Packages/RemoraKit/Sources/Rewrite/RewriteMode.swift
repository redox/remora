import Foundation
import Storage

public enum RewriteMode: Sendable, Equatable {
    case selection(NSRange), full, draft, draftAtCaret(Int), question(String)

    /// `/q` (after optional leading whitespace, then whitespace or the end) asks a question; otherwise
    /// a non-empty selection rewrites the selection. Other fields get new text at the caret.
    public static func decide(value: String, selection: NSRange?, placeholder: String?) -> RewriteMode {
        let body = value.drop(while: \.isWhitespace)
        if body.hasPrefix("/q") {
            let rest = body.dropFirst(2)
            if rest.isEmpty || rest.first?.isWhitespace == true {
                return .question(rest.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        if let selection, selection.length > 0 { return .selection(selection) }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .draft }
        if let placeholder, trimmed == placeholder.trimmingCharacters(in: .whitespacesAndNewlines) { return .draft }
        return .draftAtCaret(selection?.location ?? value.utf16.count)
    }
}

public extension InlineMode {
    init(_ m: RewriteMode) {
        switch m {
        case .selection: self = .selection
        case .full: self = .full
        case .draft, .draftAtCaret: self = .draft
        case .question: self = .question
        }
    }
}
