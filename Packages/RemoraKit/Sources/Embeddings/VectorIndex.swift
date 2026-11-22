import Foundation
import Storage

/// Brute-force cosine (dot product of unit vectors) scan over the stored vectors. Decoded vectors
/// are cached per identity and reloaded only when `EmbeddingStore.fingerprint()` changes. Rows of
/// another identity are ignored.
public actor VectorIndex {
    private let store: EmbeddingStore
    private var cache: (identity: EmbedderIdentity, fingerprint: String, rows: [(EmbeddingOwner, Int64, [Float])])?

    public init(db: AppDatabase) { store = EmbeddingStore(db) }

    public func search(_ query: [Float], identity: EmbedderIdentity, owners: Set<EmbeddingOwner>, limit: Int)
        throws -> [(owner: EmbeddingOwner, id: Int64, score: Float)] {
        guard limit > 0, query.count == identity.dimension else { return [] }
        let fingerprint = try store.fingerprint()
        if cache?.identity != identity || cache?.fingerprint != fingerprint {
            cache = (identity, fingerprint, try store.all(identity: identity, owners: Set(EmbeddingOwner.allCases)))
        }
        var hits: [(owner: EmbeddingOwner, id: Int64, score: Float)] = []
        for (owner, id, v) in cache?.rows ?? [] where owners.contains(owner) {
            var s: Float = 0
            for i in 0..<query.count { s += query[i] * v[i] }
            hits.append((owner, id, s))
        }
        hits.sort { $0.score > $1.score }
        return Array(hits.prefix(limit))
    }
}
