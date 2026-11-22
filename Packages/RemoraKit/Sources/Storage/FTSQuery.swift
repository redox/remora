import Foundation

public enum FTSQuery {
    /// Builds a safe FTS5 MATCH expression, or nil when there are no searchable tokens.
    public static func make(from userQuery: String) -> String? {
        let tokens = userQuery
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        var parts = tokens.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        parts[parts.count - 1] += "*"
        return parts.joined(separator: " ")
    }

    /// OR-joined MATCH expression: each term sanitized like `make`, quoted, prefixed `*` on its
    /// last token. Nil when no term has searchable tokens.
    public static func makeAny(terms: [String]) -> String? {
        let parts = terms.compactMap { make(from: $0) }
        return parts.isEmpty ? nil : parts.joined(separator: " OR ")
    }
}
