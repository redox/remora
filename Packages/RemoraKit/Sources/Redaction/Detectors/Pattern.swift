import Foundation

/// A compiled regular expression plus the capture group(s) that hold the sensitive part
/// (0 = whole match). With several groups (alternatives), the first one that participated in
/// the match is used. Patterns are written to avoid nested unbounded quantifiers.
struct Pattern: Sendable {
    let regex: NSRegularExpression
    let groups: [Int]

    init(_ pattern: String, group: Int = 0, options: NSRegularExpression.Options = []) {
        self.init(pattern, groups: [group], options: options)
    }

    init(_ pattern: String, groups: [Int], options: NSRegularExpression.Options = []) {
        // Patterns are compile-time constants; a failure is a programmer error.
        regex = try! NSRegularExpression(pattern: pattern, options: options)
        self.groups = groups
    }

    /// Calls `body` with each match's sensitive range, as a string range and its text.
    /// Empty ranges (e.g. an empty quoted value) are skipped.
    func forEachMatch(in text: String, _ body: (Range<String.Index>, Substring) -> Void) {
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        regex.enumerateMatches(in: text, options: [], range: full) { match, _, _ in
            guard let match,
                  let group = groups.first(where: { match.range(at: $0).location != NSNotFound }),
                  let range = Range(match.range(at: group), in: text), !range.isEmpty else { return }
            body(range, text[range])
        }
    }

    func ranges(in text: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        forEachMatch(in: text) { range, _ in out.append(range) }
        return out
    }
}
