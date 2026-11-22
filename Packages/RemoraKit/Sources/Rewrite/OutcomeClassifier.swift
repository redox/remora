import Foundation
import Storage

public enum OutcomeClassifier {
    static let editedThreshold = 0.5
    private static let maxFieldWords = 20_000
    /// Bounds the LCS (inserted × field words) for very long insertions.
    static let maxInsertedWords = 2_000

    /// nil when the field is unreadable, gone or empty (a sent message clears its field: that says
    /// nothing about the text). `.kept` when the field still contains the inserted
    /// text (whitespace-normalized), `.edited` when most of its words survive in order, else `.discarded`.
    public static func classify(inserted: String, fieldNow: String?) -> InlineOutcome? {
        guard let fieldNow, !fieldNow.allSatisfy(\.isWhitespace) else { return nil }
        let a = normalize(inserted), b = normalize(fieldNow)
        if b.contains(a) { return .kept }
        let aw = Array(words(a).prefix(maxInsertedWords)), bw = Array(words(b).prefix(maxFieldWords))
        guard !aw.isEmpty else { return .discarded }
        return Double(lcs(aw, bw)) / Double(aw.count) >= editedThreshold ? .edited : .discarded
    }

    private static func normalize(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func words(_ s: String) -> [String] {
        s.split(separator: " ").map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty }
    }

    private static func lcs(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var prev = [Int](repeating: 0, count: b.count + 1)
        var cur = prev
        for x in a {
            for (j, y) in b.enumerated() {
                cur[j + 1] = x == y ? prev[j] + 1 : max(prev[j + 1], cur[j])
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}
