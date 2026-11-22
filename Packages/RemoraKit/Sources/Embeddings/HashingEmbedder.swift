import Foundation
import Storage

/// Deterministic word-hashing embedder for tests and previews: accent- and case-folded words are
/// hashed (FNV-1a) into `dimension` buckets, then L2-normalised.
public struct HashingEmbedder: Embedder {
    private let dimension: Int
    private let revision: Int

    public init(dimension: Int = 64, revision: Int = 1) {
        self.dimension = max(1, dimension)
        self.revision = revision
    }

    public func identity() async -> EmbedderIdentity? {
        EmbedderIdentity(modelID: "hashing", revision: revision, dimension: dimension)
    }

    public func embed(_ text: String) async throws -> [Float] {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let words = folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        guard !words.isEmpty else { throw EmbeddingError.emptyInput }
        var v = [Float](repeating: 0, count: dimension)
        for word in words {
            var h: UInt64 = 0xcbf29ce484222325
            for b in word.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
            v[Int(h % UInt64(dimension))] += 1
        }
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return v.map { $0 / norm }
    }
}
