import Capture
import Embeddings
import Foundation
import GRDB
import Storage

public enum MemoryScope: String, Sendable, CaseIterable {
    case chronicle, wikiPage, wikiFact, snapshot
}

/// One retrieved memory row.
public struct MemoryHit: Sendable, Equatable {
    public var scope: MemoryScope
    public var id: Int64
    /// The period key (chronicle), the page title (page, and a fact's page), or "app — window"
    /// (snapshot).
    public var title: String
    public var snippet: String
    /// When the row applies: period start, page last seen, fact last confirmed, snapshot capture.
    public var at: Date
    /// The wiki page's slug (pages and facts).
    public var slug: String?
    /// The fused (RRF) score; higher is better.
    public var score: Double

    public init(scope: MemoryScope, id: Int64, title: String, snippet: String, at: Date, slug: String?, score: Double) {
        self.scope = scope; self.id = id; self.title = title; self.snippet = snippet; self.at = at
        self.slug = slug; self.score = score
    }
}

/// Hybrid memory search: one bm25 list per FTS scope and one vector list over the non-snapshot
/// scopes, fused by rank (`RRF`, k = 60). bm25 scores of different FTS tables are not comparable,
/// so pages and facts are separate lists (F-16).
///
/// - No embedder, no usable identity, an empty query or a vector failure: FTS only.
/// - Snapshot hits pass `SnapshotPolicy` under `policy()`; derived hits pass `DerivedPolicy`
///   (rows citing only now-excluded snapshots are dropped). Invalidated facts are never returned.
/// - Never logs the query, terms or results.
public struct HybridSearch: Sendable {
    /// Vector candidates fetched (top by cosine).
    public static let vectorLimit = 50
    /// A hit's snippet is cut here before any budget applies.
    public static let snippetChars = 1_000
    /// Characters of query text embedded.
    static let queryChars = 1_000

    private let db: AppDatabase
    private let embedder: (any Embedder)?
    private let index: VectorIndex?
    private let policy: @Sendable () -> CapturePolicy

    public init(db: AppDatabase, embedder: (any Embedder)?, index: VectorIndex?,
                policy: @escaping @Sendable () -> CapturePolicy) {
        self.db = db; self.embedder = embedder; self.index = index; self.policy = policy
    }

    private struct Key: Hashable { var scope: MemoryScope; var id: Int64 }

    /// The best `limit` hits over `scopes`, best first. `terms` drive FTS, `query` the vector
    /// list. `since`/`until` keep rows that apply in that window (a chronicle when its period
    /// overlaps it). `policy`: the caller's policy for this request (one load per rewrite), else
    /// `policy()` of the initializer.
    public func search(query: String, terms: [String], scopes: Set<MemoryScope>, since: Date? = nil, until: Date? = nil,
                       limit: Int = 10, policy: CapturePolicy? = nil) async throws -> [MemoryHit] {
        guard limit > 0, !scopes.isEmpty else { return [] }
        let perList = max(limit * 3, 30)
        var lists: [[Key]] = []
        if !terms.isEmpty {
            if scopes.contains(.chronicle) {
                lists.append(try ChronicleStore(db).search(terms, levels: Set(ChronicleLevel.allCases), since: since,
                                                           limit: perList).compactMap { c, _ in c.id.map { Key(scope: .chronicle, id: $0) } })
            }
            if scopes.contains(.wikiPage) {
                lists.append(try WikiStore(db).searchPages(terms, type: nil, limit: perList)
                    .compactMap { p, _ in p.id.map { Key(scope: .wikiPage, id: $0) } })
            }
            if scopes.contains(.wikiFact) {
                lists.append(try WikiStore(db).searchFacts(terms, type: nil, limit: perList)
                    .compactMap { f, _ in f.id.map { Key(scope: .wikiFact, id: $0) } })
            }
            if scopes.contains(.snapshot) {
                lists.append(try SnapshotStore(db).searchAny(terms: terms, since: since, limit: perList)
                    .map { Key(scope: .snapshot, id: $0.id) })
            }
        }
        try Task.checkCancellation()
        let vector = await vectorList(query: query, scopes: scopes)
        if !vector.isEmpty { lists.append(vector) }
        let fused = RRF.fuse(lists.filter { !$0.isEmpty })
        guard !fused.isEmpty else { return [] }
        try Task.checkCancellation()

        let rows = try materialize(Set(fused.map(\.0)), terms: terms, policy: policy ?? self.policy())
        var hits: [MemoryHit] = []
        for (key, score) in fused where hits.count < limit {
            guard let row = rows[key], Self.applies(row, since: since, until: until) else { continue }
            var hit = row.hit
            hit.score = score
            hits.append(hit)
        }
        return hits
    }

    // MARK: -

    /// The vector list over the non-snapshot scopes; empty when vectors cannot be used. A row with
    /// no similarity (cosine ≤ 0) is not a match.
    private func vectorList(query: String, scopes: Set<MemoryScope>) async -> [Key] {
        let owners = Set(scopes.compactMap(Self.owner))
        let text = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.queryChars))
        guard !owners.isEmpty, !text.isEmpty, let embedder, let index,
              let identity = EmbeddingIndexer.usable(await embedder.identity()),
              let vector = try? await embedder.embed(text), vector.count == identity.dimension,
              let found = try? await index.search(vector, identity: identity, owners: owners, limit: Self.vectorLimit)
        else { return [] }
        return found.filter { $0.score > 0 }.map { Key(scope: Self.scope($0.owner), id: $0.id) }
    }

    private static func owner(_ scope: MemoryScope) -> EmbeddingOwner? {
        switch scope {
        case .chronicle: .chronicle
        case .wikiPage: .wikiPage
        case .wikiFact: .wikiFact
        case .snapshot: nil
        }
    }

    private static func scope(_ owner: EmbeddingOwner) -> MemoryScope {
        switch owner {
        case .chronicle: .chronicle
        case .wikiPage: .wikiPage
        case .wikiFact: .wikiFact
        }
    }

    /// A hit (score 0) and the end of the time it applies to (a chronicle's period end, else `at`).
    private struct Found { var hit: MemoryHit; var end: Date }

    /// The rows behind `keys` that may be shown under `policy`. Missing rows, invalidated facts and
    /// excluded rows are absent; a fact follows its page (a page `DerivedPolicy` drops takes its
    /// facts with it, so its title never shows through a fact).
    private func materialize(_ keys: Set<Key>, terms: [String], policy: CapturePolicy) throws -> [Key: Found] {
        func ids(_ scope: MemoryScope) -> [Int64] { keys.filter { $0.scope == scope }.map(\.id) }
        return try db.reader.read { d in
            var out: [Key: Found] = [:]
            func put(_ hit: MemoryHit, end: Date? = nil) {
                out[Key(scope: hit.scope, id: hit.id)] = Found(hit: hit, end: end ?? hit.at)
            }
            let chronicles = try DerivedPolicy.filter(try Chronicle.fetchAll(d, keys: ids(.chronicle)), ids: \.snapshotIDs,
                                                      policy: policy, in: d)
            for c in chronicles {
                guard let id = c.id else { continue }
                put(MemoryHit(scope: .chronicle, id: id, title: c.periodKey, snippet: Self.cut(c.summary),
                              at: c.periodStart, slug: nil, score: 0), end: c.periodEnd)
            }
            let pages = try DerivedPolicy.filter(try WikiPage.fetchAll(d, keys: ids(.wikiPage)), ids: \.snapshotIDs,
                                                 policy: policy, in: d)
            for p in pages {
                guard let id = p.id else { continue }
                put(MemoryHit(scope: .wikiPage, id: id, title: p.title,
                              snippet: Self.cut(p.summary.isEmpty ? p.body : p.summary), at: p.lastSeen,
                              slug: p.slug, score: 0))
            }
            let facts = try DerivedPolicy.filter(try WikiFact.fetchAll(d, keys: ids(.wikiFact)).filter { $0.invalidAt == nil },
                                                 ids: \.snapshotIDs, policy: policy, in: d)
            let slugs = Array(Set(facts.map(\.slug)))
            var titles: [String: String] = [:]
            if !slugs.isEmpty {
                let marks = Array(repeating: "?", count: slugs.count).joined(separator: ",")
                let owners = try WikiPage.fetchAll(d, sql: "SELECT * FROM wiki_pages WHERE slug IN (\(marks))",
                                                   arguments: StatementArguments(slugs))
                for page in try DerivedPolicy.filter(owners, ids: \.snapshotIDs, policy: policy, in: d) {
                    titles[page.slug] = page.title
                }
            }
            for f in facts {
                guard let id = f.id, let title = titles[f.slug] else { continue }
                put(MemoryHit(scope: .wikiFact, id: id, title: title, snippet: Self.cut(f.fact),
                              at: f.lastConfirmedAt, slug: f.slug, score: 0))
            }
            for s in try Snapshot.fetchAll(d, keys: ids(.snapshot)) where SnapshotPolicy.allows(s, policy: policy) {
                guard let id = s.id else { continue }
                let title = s.windowTitle.map { $0.isEmpty ? s.app : "\(s.app) — \($0)" } ?? s.app
                put(MemoryHit(scope: .snapshot, id: id, title: title,
                              snippet: Self.cut(Excerpt.around(terms: terms, in: s.text, radius: 250)),
                              at: s.capturedAt, slug: nil, score: 0))
            }
            return out
        }
    }

    private static func cut(_ s: String) -> String { String(s.prefix(snippetChars)) }

    /// A row applies when the time it covers overlaps [since, until): a chronicle's period, any
    /// other row's `at`.
    private static func applies(_ row: Found, since: Date?, until: Date?) -> Bool {
        if let until, row.hit.at >= until { return false }
        if let since, row.end < since { return false }
        return true
    }
}
