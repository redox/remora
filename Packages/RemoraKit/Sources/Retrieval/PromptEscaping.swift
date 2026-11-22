import Foundation
import Synchronization

/// The one tag escaper for every prompt that puts captured or derived text inside tagged
/// untrusted sections (rewrite and the memory pipelines, F-28).
///
/// An opener (`<`, or its fullwidth `＜` / small-form `﹤` look-alikes), then optionally `/`, then
/// one of the given tag names, is neutralised to `‹`, with whitespace, invisible format characters
/// (zero-width space/joiners, word joiner, BOM, soft hyphen: Cf) and nonspacing marks
/// (combining grapheme joiner, variation selectors, combining accents: Mn) tolerated anywhere in
/// between, since a model may read past them. A longer name (`<windows>`, `<memory-x>`) is left
/// alone.
public enum PromptEscaping {
    private static let junk = "[\\s\\p{Cf}\\p{Mn}]*"
    private static let opener = "[<\u{FF1C}\u{FE64}]"
    private static let cache = Mutex<[[String]: NSRegularExpression]>([:])

    /// Neutralises opening and closing tags of each name in `tags` so captured text can neither
    /// close a section nor open a fake one.
    public static func escape(_ s: String, tags: [String]) -> String {
        guard !tags.isEmpty else { return s }
        return regex(for: tags).stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s),
                                                         withTemplate: "‹")
    }

    private static func regex(for tags: [String]) -> NSRegularExpression {
        if let cached = cache.withLock({ $0[tags] }) { return cached }
        let names = tags.map { $0.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: junk) }
        let pattern = opener + "(?=" + junk + "[/\u{FF0F}]?" + junk + "(?:" + names.joined(separator: "|") + ")(?![\\p{L}\\p{N}_-]))"
        // Built only from escaped literal names: it always compiles.
        let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        cache.withLock { $0[tags] = regex }
        return regex
    }
}
