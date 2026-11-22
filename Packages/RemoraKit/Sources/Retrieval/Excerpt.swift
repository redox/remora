import Foundation

public enum Excerpt {
    /// A window of `2·radius` characters around the earliest accent/case-insensitive match of any
    /// term; the first `2·radius` characters when nothing matches. `…` marks each cut.
    public static func around(terms: [String], in text: String, radius: Int = 500) -> String {
        let total = text.count
        guard total > 2 * radius else { return text }
        var best: String.Index?
        for term in terms where !term.isEmpty {
            if let r = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]),
               best == nil || r.lowerBound < best! { best = r.lowerBound }
        }
        guard let hit = best else { return String(text.prefix(2 * radius)) + "…" }
        let pos = text.distance(from: text.startIndex, to: hit)
        var lo = max(0, pos - radius)
        var hi = lo + 2 * radius
        if hi > total { hi = total; lo = max(0, hi - 2 * radius) }
        let a = text.index(text.startIndex, offsetBy: lo)
        let b = text.index(text.startIndex, offsetBy: hi)
        return (lo > 0 ? "…" : "") + text[a..<b] + (hi < total ? "…" : "")
    }
}
