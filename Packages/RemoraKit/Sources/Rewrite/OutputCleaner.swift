import Foundation

public enum OutputCleaner {
    /// Strips one surrounding code fence and one pair of wrapping quotes when `original` has neither,
    /// trims, then reapplies the original whitespace or the draft’s spacing at a caret.
    public static func clean(_ raw: String, original: String, keepsDraftSpacing: Bool = false) -> String {
        var s = raw
        if !original.unicodeScalars.contains("\r") { s = s.replacingOccurrences(of: "\r\n", with: "\n") }
        let boundaryText = keepsDraftSpacing ? s : original
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Fenced bodies keep their first line's indentation (code); only blank edges go.
        if !original.contains("```"), let body = stripFence(s) { s = trimBlankEdges(body) }
        if !hasWrappingQuotes(original), let inner = stripQuotes(s) { s = inner.trimmingCharacters(in: .whitespacesAndNewlines) }
        let lead = boundaryText.prefix(while: \.isWhitespace)
        let trail = boundaryText.reversed().prefix(while: \.isWhitespace).reversed()
        if lead.count == boundaryText.count { return s }
        return String(lead) + s + String(trail)
    }

    private static let pairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("«", "»")]

    /// The body of one fence wrapping the whole output, or nil. A body holding another ``` means
    /// the output is several fenced blocks (or prose between fences): left as is.
    private static func stripFence(_ s: String) -> String? {
        guard s.hasPrefix("```"), s.hasSuffix("```"), s.count >= 6 else { return nil }
        var body = s.dropFirst(3).dropLast(3)
        guard !body.contains("```") else { return nil }
        // An info string (```swift) occupies the rest of the first line.
        if let nl = body.firstIndex(of: "\n") {
            let info = body[..<nl]
            if !info.contains(where: \.isWhitespace) { body = body[body.index(after: nl)...] }
        }
        return String(body)
    }

    /// Drops leading blank lines (not the first line's indentation) and trailing whitespace.
    private static func trimBlankEdges(_ s: String) -> String {
        var lines = s.split(separator: "\n", omittingEmptySubsequences: false)
        while let first = lines.first, first.allSatisfy(\.isWhitespace), lines.count > 1 { lines.removeFirst() }
        let joined = lines.joined(separator: "\n")
        return String(joined.reversed().drop(while: \.isWhitespace).reversed())
    }

    private static func stripQuotes(_ s: String) -> String? {
        guard s.count >= 2, let f = s.first, let l = s.last else { return nil }
        for (open, close) in pairs where f == open && l == close {
            let inner = s.dropFirst().dropLast()
            if !inner.contains(open) && !inner.contains(close) { return String(inner) }
        }
        return nil
    }

    private static func hasWrappingQuotes(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let f = t.first, let l = t.last else { return false }
        return pairs.contains { f == $0.0 && l == $0.1 }
    }
}
