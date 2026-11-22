import Foundation

/// The one text-matching normalisation for memory (F-66): quote checks, slugs, entity resolution,
/// time rules, style merges and dedupe keys all compare text through it, so they agree on what
/// "the same words" means.
public enum TextFold {
    /// Case- and diacritic-folded (locale-independent), typographic quotes mapped to ASCII
    /// (`’ ‘ ´ \`` → `'`, `“ ” « »` → `"`), invisible format characters (Cf: zero-width space,
    /// joiners, soft hyphen, BOM) removed, and whitespace runs collapsed to one space, trimmed.
    public static func fold(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var out = ""
        out.reserveCapacity(folded.unicodeScalars.count)
        var pendingSpace = false
        for scalar in folded.unicodeScalars {
            if scalar.properties.isWhitespace {
                pendingSpace = !out.isEmpty
                continue
            }
            if scalar.properties.generalCategory == .format { continue }
            if pendingSpace { out.append(" "); pendingSpace = false }
            switch scalar {
            case "\u{2019}", "\u{2018}", "\u{00B4}", "`": out.append("'")
            case "\u{201C}", "\u{201D}", "\u{00AB}", "\u{00BB}": out.append("\"")
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// The folded text's words: maximal runs of letters and digits.
    public static func words(_ text: String) -> Set<String> {
        Set(tokens(text))
    }

    /// A comparison key: the folded text's words in order, joined by one space ("L'offsite
    /// d’Oslo !" → "l offsite d oslo"). Two texts that differ only in case, accents, quotes,
    /// punctuation or spacing share a key (slugs, mentions, flag dedupe keys).
    ///
    /// With `keepingSymbols`, each of `+ # % € $ -` is kept as a token of its own, so values
    /// that differ only by such a symbol stay distinct ("C" / "C++", "12k$" / "12k€",
    /// "-5%" / "5%"): the key for facts.
    public static func key(_ text: String, keepingSymbols: Bool = false) -> String {
        tokens(text, keeping: keepingSymbols ? keptSymbols : []).joined(separator: " ")
    }

    /// The symbols `key(_:keepingSymbols: true)` keeps.
    public static let keptSymbols: Set<Character> = ["+", "#", "%", "€", "$", "-"]

    private static func tokens(_ text: String, keeping symbols: Set<Character> = []) -> [String] {
        // `Œ`/`œ` and `Æ`/`æ` do not decompose; spell them out so "Œuvre" and "oeuvre" agree.
        let folded = fold(text).replacingOccurrences(of: "œ", with: "oe").replacingOccurrences(of: "æ", with: "ae")
        var out: [String] = []
        var word = ""
        for c in folded {
            if c.isLetter || c.isNumber { word.append(c); continue }
            if !word.isEmpty { out.append(word); word = "" }
            if symbols.contains(c) { out.append(String(c)) }
        }
        if !word.isEmpty { out.append(word) }
        return out
    }

    /// Word-set Jaccard similarity in [0, 1]; 0 when both texts have no words.
    public static func jaccard(_ a: String, _ b: String) -> Double {
        let x = words(a), y = words(b)
        let union = x.union(y).count
        return union == 0 ? 0 : Double(x.intersection(y).count) / Double(union)
    }
}
