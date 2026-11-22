import Foundation

public enum QueryTerms {
    /// Words of 4+ characters, case-folded, deduplicated in order of first appearance; stopwords and
    /// pure numbers are skipped.
    public static func extract(from texts: [String], max: Int = 8) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for text in texts {
            for raw in text.components(separatedBy: CharacterSet.alphanumerics.inverted) where raw.count >= 4 {
                let word = raw.lowercased()
                guard word.contains(where: \.isLetter), !stopwords.contains(word), seen.insert(word).inserted else { continue }
                out.append(word)
                if out.count >= max { return out }
            }
        }
        return out
    }

    private static let stopwords: Set<String> = [
        // French
        "avec", "dans", "pour", "cette", "cela", "ceci", "mais", "donc", "alors", "elle", "elles", "nous", "vous", "leur",
        "leurs", "sont", "sera", "être", "etre", "fait", "plus", "tout", "tous", "toute", "comme", "aussi", "entre", "sans",
        "chez", "très", "tres", "bien",
        // English
        "that", "with", "this", "from", "have", "your", "will", "would", "could", "should", "there", "their", "they",
        "them", "then", "than", "what", "when", "where", "which", "about", "been", "were", "also", "into", "just", "some",
    ]
}
