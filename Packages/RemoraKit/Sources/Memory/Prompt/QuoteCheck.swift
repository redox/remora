import Foundation
import Storage

/// Generate-then-verify for quotes a model cites as evidence (salient flags, loop closures,
/// nudges): a quote counts only when it is literally in the cited text.
public enum QuoteCheck {
    /// Shorter quotes ("deck", "ok") would match almost anything.
    public static let minimumLength = 12
    private static let wrapping = CharacterSet(charactersIn: "\"' ")

    /// True when the quote, folded by `TextFold` (case, diacritics, typographic quotes,
    /// whitespace) and without the quotation marks a model may wrap it in, has at least
    /// `minimumLength` characters and occurs in the folded text.
    public static func verify(_ quote: String, in text: String) -> Bool {
        let q = TextFold.fold(quote).trimmingCharacters(in: wrapping)
        guard q.count >= minimumLength else { return false }
        return TextFold.fold(text).contains(q)
    }
}
