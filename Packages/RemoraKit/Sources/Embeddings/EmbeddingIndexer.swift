import CryptoKit
import Foundation
import GRDB
import Storage

public struct EmbeddingSource: Sendable, Equatable {
    public var owner: EmbeddingOwner
    public var id: Int64
    public var text: String
    public var hash: String
}

/// Keeps `embeddings` in step with chronicles, wiki pages and valid facts. "Which rows are
/// pending" is `EmbeddingStore`'s one shared predicate (F-11); this type only adds the text and
/// the content hash, and writes through `DataGeneration.write` (F-12).
public struct EmbeddingIndexer: Sendable {
    private let db: AppDatabase
    private let embedder: any Embedder
    private static let bodyPrefix = 1_000

    public init(db: AppDatabase, embedder: any Embedder) {
        self.db = db
        self.embedder = embedder
    }

    /// Every source row with its embedding text and SHA-256 hex hash.
    public static func sources(_ d: Database) throws -> [EmbeddingSource] {
        var result: [EmbeddingSource] = []
        for row in try Row.fetchAll(d, sql: "SELECT id, summary FROM chronicle ORDER BY id") {
            result.append(make(.chronicle, row["id"], row["summary"]))
        }
        for row in try Row.fetchAll(d, sql: "SELECT id, title, summary, body FROM wiki_pages ORDER BY id") {
            result.append(make(.wikiPage, row["id"], pageText(row)))
        }
        for row in try Row.fetchAll(d, sql: """
            SELECT f.id, f.fact, p.title FROM wiki_facts f JOIN wiki_pages p ON p.slug = f.slug
            WHERE f.invalid_at IS NULL ORDER BY f.id
            """) {
            result.append(make(.wikiFact, row["id"], factText(row)))
        }
        return result
    }

    static func source(_ owner: EmbeddingOwner, id: Int64, in d: Database) throws -> EmbeddingSource? {
        switch owner {
        case .chronicle:
            return try String.fetchOne(d, sql: "SELECT summary FROM chronicle WHERE id = ?", arguments: [id])
                .map { make(owner, id, $0) }
        case .wikiPage:
            return try Row.fetchOne(d, sql: "SELECT title, summary, body FROM wiki_pages WHERE id = ?", arguments: [id])
                .map { make(owner, id, pageText($0)) }
        case .wikiFact:
            return try Row.fetchOne(d, sql: """
                SELECT f.fact, p.title FROM wiki_facts f JOIN wiki_pages p ON p.slug = f.slug
                WHERE f.id = ? AND f.invalid_at IS NULL
                """, arguments: [id]).map { make(owner, id, factText($0)) }
        }
    }

    private static func pageText(_ row: Row) -> String {
        let title: String = row["title"], summary: String = row["summary"], body: String = row["body"]
        return title + "\n" + summary + "\n" + String(body.prefix(bodyPrefix))
    }

    private static func factText(_ row: Row) -> String {
        let title: String = row["title"], fact: String = row["fact"]
        return title + ": " + fact
    }

    private static func make(_ owner: EmbeddingOwner, _ id: Int64, _ text: String) -> EmbeddingSource {
        EmbeddingSource(owner: owner, id: id, text: text, hash: SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined())
    }

    private struct Candidate { var source: EmbeddingSource; var needsVector: Bool }

    /// The shared pending rows with their text; `needsVector` is false when the stored vector's
    /// content hash and model already match (the source row was only touched).
    private static func candidates(_ db: AppDatabase, identity: EmbedderIdentity, limit: Int) throws -> [Candidate] {
        try db.reader.read { d in
            var result: [Candidate] = []
            for p in try EmbeddingStore.pendingSources(identity: identity.pendingIdentity, limit: limit, in: d) {
                guard let owner = EmbeddingOwner(rawValue: p.ownerTable),
                      let source = try source(owner, id: p.ownerID, in: d) else { continue }
                let stored = try EmbeddingStore.stored(owner: owner, ownerID: p.ownerID, in: d)
                let current = stored.map { $0.contentHash == source.hash && $0.modelID == identity.modelID
                    && $0.revision == identity.revision } ?? false
                result.append(Candidate(source: source, needsVector: !current))
            }
            return result
        }
    }

    /// Rows that need a vector: no vector, source changed since, or made by another model/revision.
    /// With the embedder unavailable, revision is ignored.
    public func pendingCount() async throws -> Int {
        let identity = await embedder.identity()?.pendingIdentity
        return try EmbeddingStore(db).pendingSourceCount(identity: identity)
    }

    /// An identity with no dimension cannot make a vector: it counts as unavailable.
    public static func usable(_ identity: EmbedderIdentity?) -> EmbedderIdentity? {
        guard let identity, identity.dimension >= 1 else { return nil }
        return identity
    }

    /// Embeds up to `limit` pending rows and writes them in one generation-checked transaction, then
    /// drops vectors of deleted owners and invalidated facts. A run that straddles a delete-all throws
    /// `DataGeneration.Stale` and writes nothing. Returns the number of vectors written (rows that
    /// cannot be embedded get an empty tombstone row, so they leave the pending set until their source
    /// changes; they are not counted). The caller must capture `at` before the run reads its
    /// candidates, so a source edited during the run is still newer than the vector.
    @discardableResult
    public func run(limit: Int = 200, at: Date, generation: Int) async throws -> Int {
        // Vectors of deleted owners and invalidated facts go even when the embedder is unavailable.
        _ = try DataGeneration.write(db, expected: generation) { try EmbeddingStore.deleteOrphans(in: $0) }
        guard let identity = Self.usable(await embedder.identity()) else { return 0 }
        struct Item { var source: EmbeddingSource; var vector: [Float]?; var tombstone = false }
        let candidates = try Self.candidates(db, identity: identity, limit: limit)
        var items: [Item] = []
        for c in candidates {
            if !c.needsVector { items.append(Item(source: c.source, vector: nil)); continue }
            do {
                let v = try await embedder.embed(c.source.text)
                if v.count == identity.dimension {
                    items.append(Item(source: c.source, vector: v))
                } else {
                    items.append(Item(source: c.source, vector: [], tombstone: true))
                }
            } catch EmbeddingError.emptyInput {
                items.append(Item(source: c.source, vector: [], tombstone: true))
            }
        }
        return try DataGeneration.write(db, expected: generation) { d in
            var written = 0
            for item in items {
                if let v = item.vector {
                    try EmbeddingStore.upsert(owner: item.source.owner, ownerID: item.source.id, identity: identity,
                                              vector: v, contentHash: item.source.hash, at: at, in: d)
                    if !item.tombstone { written += 1 }
                } else {
                    try EmbeddingStore.touch(owner: item.source.owner, ownerID: item.source.id, at: at, in: d)
                }
            }
            try EmbeddingStore.deleteOrphans(in: d)
            return written
        }
    }
}
