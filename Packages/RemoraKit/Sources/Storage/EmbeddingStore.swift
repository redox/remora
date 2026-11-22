import Foundation
import GRDB

/// Which embedding model produced (or should produce) the stored vectors. A row made by another
/// model or revision counts as pending when an identity is given.
public struct EmbeddingIdentity: Sendable, Equatable {
    public var modelID: String
    public var revision: Int
    public init(modelID: String, revision: Int) { self.modelID = modelID; self.revision = revision }
}

/// The model that makes (or made) a vector. `modelID`/`revision` must match for a vector to be used.
public struct EmbedderIdentity: Sendable, Equatable, Hashable {
    public var modelID: String
    public var revision: Int
    public var dimension: Int
    public init(modelID: String, revision: Int, dimension: Int) {
        self.modelID = modelID; self.revision = revision; self.dimension = dimension
    }
    public var pendingIdentity: EmbeddingIdentity { EmbeddingIdentity(modelID: modelID, revision: revision) }
}

/// `embeddings.owner_table` values.
public enum EmbeddingOwner: String, Sendable, CaseIterable {
    case chronicle, wikiPage = "wiki_pages", wikiFact = "wiki_facts"
}

/// Queries over `embeddings` shared by the planner (Task 3) and the indexer (Task 4), so the
/// "what still needs a vector" rule has exactly one definition (F-11).
public struct EmbeddingStore: Sendable {
    /// Owner tables that get vectors: chronicles, wiki pages and valid wiki facts.
    public static let ownerTables = ["chronicle", "wiki_pages", "wiki_facts"]

    private let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    /// Source rows with no vector, or whose source changed after the vector was made
    /// (`generated_at` / `updated_at` / `last_confirmed_at` later than `embeddings.created_at`).
    /// With an `identity`, rows whose vector comes from another model or revision are pending too;
    /// with nil the revision is ignored.
    public func pendingSourceCount(identity: EmbeddingIdentity?) throws -> Int {
        try db.reader.read { d in try Self.pendingSourceCount(identity: identity, in: d) }
    }

    public static func pendingSourceCount(identity: EmbeddingIdentity?, in d: Database) throws -> Int {
        var total = 0
        for source in sources {
            let (sql, arguments) = pendingQuery(source, select: "COUNT(*)", identity: identity)
            total += try Int.fetchOne(d, sql: sql, arguments: arguments) ?? 0
        }
        return total
    }

    /// A source row that needs a vector.
    public struct PendingSource: Sendable, Equatable {
        public var ownerTable: String
        public var ownerID: Int64
        public init(ownerTable: String, ownerID: Int64) { self.ownerTable = ownerTable; self.ownerID = ownerID }
    }

    /// The first `limit` pending rows (chronicle, then pages, then facts; by id). Same predicate as
    /// `pendingSourceCount`.
    public func pendingSources(identity: EmbeddingIdentity?, limit: Int) throws -> [PendingSource] {
        try db.reader.read { d in try Self.pendingSources(identity: identity, limit: limit, in: d) }
    }

    public static func pendingSources(identity: EmbeddingIdentity?, limit: Int, in d: Database) throws -> [PendingSource] {
        var result: [PendingSource] = []
        for source in sources where result.count < limit {
            var (sql, arguments) = pendingQuery(source, select: "s.id", identity: identity)
            sql += " ORDER BY s.id LIMIT ?"
            arguments += [limit - result.count]
            result += try Int64.fetchAll(d, sql: sql, arguments: arguments).map { PendingSource(ownerTable: source.table, ownerID: $0) }
        }
        return result
    }

    // MARK: Vectors (Task 4)

    /// Upserts the vector of one owner row. Use inside `DataGeneration.write` (the `in:` overload).
    public func upsert(owner: EmbeddingOwner, ownerID: Int64, identity: EmbedderIdentity, vector: [Float],
                       contentHash: String, at: Date) throws {
        try db.writer.write { d in
            try Self.upsert(owner: owner, ownerID: ownerID, identity: identity, vector: vector,
                            contentHash: contentHash, at: at, in: d)
        }
    }

    public static func upsert(owner: EmbeddingOwner, ownerID: Int64, identity: EmbedderIdentity, vector: [Float],
                              contentHash: String, at: Date, in d: Database) throws {
        try d.execute(sql: """
            INSERT INTO embeddings (owner_table, owner_id, model_id, revision, dims, vector, content_hash, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(owner_table, owner_id) DO UPDATE SET
              model_id = excluded.model_id, revision = excluded.revision, dims = excluded.dims,
              vector = excluded.vector, content_hash = excluded.content_hash, created_at = excluded.created_at
            """, arguments: [owner.rawValue, ownerID, identity.modelID, identity.revision, vector.count,
                             VectorCodec.encode(vector), contentHash, at])
    }

    /// Marks an unchanged-content row as current (its source row was touched but the text is the same).
    public static func touch(owner: EmbeddingOwner, ownerID: Int64, at: Date, in d: Database) throws {
        try d.execute(sql: "UPDATE embeddings SET created_at = ? WHERE owner_table = ? AND owner_id = ?",
                      arguments: [at, owner.rawValue, ownerID])
    }

    /// Stored (model, revision, hash) of one owner row, if any.
    public static func stored(owner: EmbeddingOwner, ownerID: Int64, in d: Database)
        throws -> (modelID: String, revision: Int, contentHash: String)? {
        try Row.fetchOne(d, sql: "SELECT model_id, revision, content_hash FROM embeddings WHERE owner_table = ? AND owner_id = ?",
                         arguments: [owner.rawValue, ownerID]).map { ($0["model_id"], $0["revision"], $0["content_hash"]) }
    }

    /// Every decodable vector made by exactly `identity` for the given owners. Rows of another
    /// model, revision or dimension are ignored.
    public func all(identity: EmbedderIdentity, owners: Set<EmbeddingOwner>) throws -> [(EmbeddingOwner, Int64, [Float])] {
        try db.reader.read { d in
            var result: [(EmbeddingOwner, Int64, [Float])] = []
            for owner in EmbeddingOwner.allCases where owners.contains(owner) {
                let rows = try Row.fetchAll(d, sql: """
                    SELECT owner_id, vector FROM embeddings
                    WHERE owner_table = ? AND model_id = ? AND revision = ? AND dims = ? ORDER BY owner_id
                    """, arguments: [owner.rawValue, identity.modelID, identity.revision, identity.dimension])
                for row in rows {
                    let data: Data = row["vector"]
                    if let v = VectorCodec.decode(data, dims: identity.dimension) { result.append((owner, row["owner_id"], v)) }
                }
            }
            return result
        }
    }

    /// Removes vectors whose owner row is gone (or is an invalidated fact). Returns the count.
    @discardableResult
    public func deleteOrphans() throws -> Int { try db.writer.write { try Self.deleteOrphans(in: $0) } }

    @discardableResult
    public static func deleteOrphans(in d: Database) throws -> Int {
        try d.execute(sql: """
            DELETE FROM embeddings WHERE
              (owner_table = 'chronicle' AND owner_id NOT IN (SELECT id FROM chronicle))
              OR (owner_table = 'wiki_pages' AND owner_id NOT IN (SELECT id FROM wiki_pages))
              OR (owner_table = 'wiki_facts' AND owner_id NOT IN (SELECT id FROM wiki_facts WHERE invalid_at IS NULL))
              OR owner_table NOT IN ('chronicle', 'wiki_pages', 'wiki_facts')
            """)
        return d.changesCount
    }

    public func delete(owner: EmbeddingOwner, ownerID: Int64) throws {
        try db.writer.write { d in
            try d.execute(sql: "DELETE FROM embeddings WHERE owner_table = ? AND owner_id = ?",
                          arguments: [owner.rawValue, ownerID])
        }
    }

    /// count + max(id) + max(created_at): changes whenever a vector is added, removed or replaced.
    public func fingerprint() throws -> String {
        try db.reader.read { d in
            let row = try Row.fetchOne(d, sql: "SELECT COUNT(*) AS n, MAX(id) AS m, MAX(created_at) AS t FROM embeddings")
            let n: Int = row?["n"] ?? 0
            let m: Int64 = row?["m"] ?? 0
            let t: String = row?["t"] ?? ""
            return "\(n)|\(m)|\(t)"
        }
    }

    private struct Source { var table: String; var changedColumn: String; var filter: String; var extraChanged: String = "" }

    private static let sources = [
        Source(table: "chronicle", changedColumn: "generated_at", filter: "1"),
        Source(table: "wiki_pages", changedColumn: "updated_at", filter: "1"),
        Source(table: "wiki_facts", changedColumn: "last_confirmed_at", filter: "s.invalid_at IS NULL",
               // Fact text embeds the page title, so a page edit after the vector also makes it pending.
               extraChanged: " OR (SELECT updated_at FROM wiki_pages WHERE slug = s.slug) > e.created_at"),
    ]

    /// The one definition of "pending": no vector, source changed after it, or (with an identity)
    /// another model or revision.
    private static func pendingQuery(_ source: Source, select: String, identity: EmbeddingIdentity?)
        -> (String, StatementArguments) {
        var sql = """
            SELECT \(select) FROM \(source.table) s
            LEFT JOIN embeddings e ON e.owner_table = '\(source.table)' AND e.owner_id = s.id
            WHERE \(source.filter) AND (e.id IS NULL OR s.\(source.changedColumn) > e.created_at\(source.extraChanged)
            """
        var arguments: StatementArguments = []
        if let identity {
            sql += " OR e.model_id <> ? OR e.revision <> ?"
            arguments = [identity.modelID, identity.revision]
        }
        return (sql + ")", arguments)
    }
}
