import Foundation
import GRDB

/// Wiki page slugs: `TextFold.key` words joined by `-`, at most `maxLength` characters
/// ("Réunion d'équipe" → "reunion-d-equipe"). Empty when the name has no letter or digit.
public enum Slug {
    public static let maxLength = 60

    public static func make(_ name: String) -> String {
        var slug = TextFold.key(name).replacingOccurrences(of: " ", with: "-")
        if slug.count > maxLength {
            slug = String(slug.prefix(maxLength))
            while slug.hasSuffix("-") { slug.removeLast() }
        }
        return slug
    }
}

public enum WikiSort: String, Sendable, CaseIterable { case recent, mentions }

/// Wiki pages (people, projects, topics, tools, organisations) and their bitemporal facts.
///
/// The `in d: Database` methods are static so a runner can call them inside
/// `DataGeneration.write` (GRDB writes are not reentrant). Callers redact LLM output before
/// storing it.
public struct WikiStore: Sendable {
    /// Pages with fewer mentions are never written up (`WikiRewritePipeline`), so "forget" blanks
    /// their write-up instead of waiting for a rewrite.
    public static let minRewriteMentions = 2

    private let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    // MARK: - Pages

    public func page(slug: String) throws -> WikiPage? {
        try db.reader.read { try Self.page(slug: slug, in: $0) }
    }

    public static func page(slug: String, in d: Database) throws -> WikiPage? {
        try WikiPage.fetchOne(d, sql: "SELECT * FROM wiki_pages WHERE slug = ?", arguments: [slug])
    }

    /// The page an entity name refers to (see `WikiNameIndex.resolve`: by its own name, then by
    /// a multi-word alias, then a bare slug collision).
    public func resolve(name: String, aliases: [String], in d: Database) throws -> WikiPage? {
        try Self.resolve(name: name, aliases: aliases, in: d)
    }

    public static func resolve(name: String, aliases: [String], in d: Database) throws -> WikiPage? {
        guard let found = try WikiNameIndex.load(in: d).resolve(name: name, aliases: aliases) else { return nil }
        return try page(slug: found.slug, in: d)
    }

    /// The `TextFold.fold` of the page's title and of each alias.
    public static func names(of page: WikiPage) -> Set<String> {
        WikiNameIndex.Entry(page).names
    }

    /// The pages whose title or an alias occurs in `text` as whole words (compared by
    /// `TextFold.key`), most recently seen first, at most `limit`.
    public static func mentionedPages(in text: String, limit: Int, in d: Database) throws -> [WikiPage] {
        try WikiNameIndex.load(in: d).mentioned(in: text, limit: limit).compactMap { try page(slug: $0, in: d) }
    }

    /// The pages most recently seen, at most `limit` (150 by default: the known-pages list of
    /// the wiki rewrite prompt, F-15).
    public func known(limit: Int = 150) throws -> [WikiPage] {
        try db.reader.read { d in
            try WikiPage.fetchAll(d, sql: "SELECT * FROM wiki_pages ORDER BY last_seen DESC, id DESC LIMIT ?",
                                  arguments: [limit])
        }
    }

    public func list(type: WikiPageType?, sort: WikiSort, limit: Int, offset: Int) throws -> [WikiPage] {
        let order = switch sort {
        case .recent: "last_seen DESC, id DESC"
        case .mentions: "mention_count DESC, last_seen DESC, id DESC"
        }
        return try db.reader.read { d in
            try WikiPage.fetchAll(d, sql: """
                SELECT * FROM wiki_pages WHERE (? IS NULL OR type = ?) ORDER BY \(order) LIMIT ? OFFSET ?
                """, arguments: [type?.rawValue, type?.rawValue, limit, offset])
        }
    }

    /// Dirty pages with at least `minMentions` mentions, most mentioned first.
    public func dirtyPages(minMentions: Int, limit: Int) throws -> [WikiPage] {
        try db.reader.read { d in
            try WikiPage.fetchAll(d, sql: """
                SELECT * FROM wiki_pages WHERE is_dirty = 1 AND mention_count >= ?
                ORDER BY mention_count DESC, last_seen DESC, id DESC LIMIT ?
                """, arguments: [minMentions, limit])
        }
    }

    /// Inserts `p` (its id is ignored) and returns it with its id.
    @discardableResult
    public static func insert(_ p: WikiPage, in d: Database) throws -> WikiPage {
        var row = p
        row.id = nil
        try row.insert(d)
        return row
    }

    /// Saves every column of an existing page (by id).
    public static func update(_ p: WikiPage, in d: Database) throws {
        try p.update(d)
    }

    /// Deletes the page, its facts (foreign-key cascade) and their vectors.
    public func delete(slug: String) throws {
        try db.writer.write { try Self.delete(slug: slug, in: $0) }
    }

    public static func delete(slug: String, in d: Database) throws {
        try d.execute(sql: "DELETE FROM wiki_pages WHERE slug = ?", arguments: [slug])
        _ = try EmbeddingStore.deleteOrphans(in: d)
    }

    // MARK: - Facts

    /// Facts still true (`invalid_at IS NULL`), oldest first.
    public func validFacts(slug: String) throws -> [WikiFact] {
        try facts(slug: slug, includeInvalid: false)
    }

    public func facts(slug: String, includeInvalid: Bool) throws -> [WikiFact] {
        try db.reader.read { try Self.facts(slug: slug, includeInvalid: includeInvalid, in: $0) }
    }

    public static func facts(slug: String, includeInvalid: Bool, in d: Database) throws -> [WikiFact] {
        try WikiFact.fetchAll(d, sql: """
            SELECT * FROM wiki_facts WHERE slug = ? AND (? OR invalid_at IS NULL) ORDER BY valid_at, id
            """, arguments: [slug, includeInvalid])
    }

    public static func fact(id: Int64, in d: Database) throws -> WikiFact? {
        try WikiFact.fetchOne(d, key: id)
    }

    /// The fact of `slug` with this key (`TextFold.key` of its text), valid or not.
    public static func fact(slug: String, normKey: String, in d: Database) throws -> WikiFact? {
        try WikiFact.fetchOne(d, sql: "SELECT * FROM wiki_facts WHERE slug = ? AND norm_key = ?",
                              arguments: [slug, normKey])
    }

    /// Inserts `f` (its id is ignored) and returns it with its id.
    @discardableResult
    public static func insert(_ f: WikiFact, in d: Database) throws -> WikiFact {
        var row = f
        row.id = nil
        try row.insert(d)
        return row
    }

    /// Saves every column of an existing fact (by id).
    public static func update(_ f: WikiFact, in d: Database) throws {
        try f.update(d)
    }

    // MARK: - User corrections

    /// No page has this slug.
    public struct NotFound: Error, Equatable, Sendable { public init() {} }
    /// The id is not a valid (still true) fact of the page.
    public struct InvalidFact: Error, Equatable, Sendable {
        public let id: Int64
        public init(_ id: Int64) { self.id = id }
    }
    /// The fact text is blank.
    public struct EmptyFact: Error, Equatable, Sendable { public init() {} }

    /// Records a fact the user stated (chat "correct the wiki"), see the static overload.
    @discardableResult
    public func addUserFact(slug: String, text: String, invalidating: [Int64], at: Date) throws -> WikiFact {
        try db.writer.write { d in try Self.addUserFact(slug: slug, text: text, invalidating: invalidating, at: at, in: d) }
    }

    /// In one transaction: stores `text` as a fact of the page with subject `user`, basis
    /// `user_stated`, worth `core` and no snapshot ids (so `DerivedPolicy` keeps it and the forget
    /// cascade never deletes it), ends each fact of `invalidating` (`invalid_at = at`,
    /// `superseded_by` the new fact), and marks the page dirty with at least
    /// `minRewriteMentions` mentions (so the rewrite picks the correction up). A fact with the
    /// same key already on the page becomes that user-stated fact (valid again). Throws
    /// `NotFound` for an unknown slug and `InvalidFact(id)` for an id that is not a valid fact of
    /// this page, before writing anything.
    @discardableResult
    public static func addUserFact(slug: String, text: String, invalidating: [Int64], at: Date,
                                   in d: Database) throws -> WikiFact {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = TextFold.key(clean, keepingSymbols: true)
        guard !clean.isEmpty, !key.isEmpty else { throw EmptyFact() }
        guard var page = try page(slug: slug, in: d) else { throw NotFound() }
        var ended: [WikiFact] = []
        for id in Array(Set(invalidating)).sorted() {
            guard let f = try fact(id: id, in: d), f.slug == slug, f.invalidAt == nil else { throw InvalidFact(id) }
            ended.append(f)
        }
        let stored: WikiFact
        if var existing = try fact(slug: slug, normKey: key, in: d) {
            existing.fact = clean
            existing.subject = .user
            existing.basis = .userStated
            existing.worth = .core
            existing.snapshotIDs = []
            if existing.invalidAt != nil { existing.validAt = at }
            existing.invalidAt = nil
            existing.supersededBy = nil
            existing.lastConfirmedAt = max(existing.lastConfirmedAt, at)
            existing.llmCallID = nil
            try update(existing, in: d)
            stored = existing
        } else {
            stored = try insert(WikiFact(slug: slug, fact: clean, normKey: key, subject: .user, basis: .userStated,
                                         worth: .core, snapshotIDs: [], validAt: at, recordedAt: at, lastConfirmedAt: at,
                                         llmCallID: nil), in: d)
        }
        for var old in ended where old.id != stored.id {
            old.invalidAt = at
            old.supersededBy = stored.id
            try update(old, in: d)
        }
        page.isDirty = true
        page.mentionCount = max(page.mentionCount, minRewriteMentions)
        try update(page, in: d)
        return stored
    }

    // MARK: - Search

    /// Full-text OR search over page titles, aliases, summaries and bodies; best first, score
    /// `-bm25` (higher is better).
    public func searchPages(_ terms: [String], type: WikiPageType?, limit: Int) throws -> [(WikiPage, Double)] {
        guard limit > 0, let match = FTSQuery.makeAny(terms: terms) else { return [] }
        return try db.reader.read { d in
            try Row.fetchAll(d, sql: """
                SELECT p.*, bm25(wiki_pages_fts) AS score
                FROM wiki_pages_fts JOIN wiki_pages p ON p.id = wiki_pages_fts.rowid
                WHERE wiki_pages_fts MATCH ? AND (? IS NULL OR p.type = ?)
                ORDER BY score, p.last_seen DESC LIMIT ?
                """, arguments: [match, type?.rawValue, type?.rawValue, limit])
                .map { row in (try WikiPage(row: row), -(row["score"] as Double)) }
        }
    }

    /// Full-text OR search over **valid** facts (of pages of `type`, when given); best first,
    /// score `-bm25`.
    public func searchFacts(_ terms: [String], type: WikiPageType?, limit: Int) throws -> [(WikiFact, Double)] {
        guard limit > 0, let match = FTSQuery.makeAny(terms: terms) else { return [] }
        return try db.reader.read { d in
            try Row.fetchAll(d, sql: """
                SELECT f.*, bm25(wiki_facts_fts) AS score
                FROM wiki_facts_fts JOIN wiki_facts f ON f.id = wiki_facts_fts.rowid
                JOIN wiki_pages p ON p.slug = f.slug
                WHERE wiki_facts_fts MATCH ? AND f.invalid_at IS NULL AND (? IS NULL OR p.type = ?)
                ORDER BY score, f.last_confirmed_at DESC LIMIT ?
                """, arguments: [match, type?.rawValue, type?.rawValue, limit])
                .map { row in (try WikiFact(row: row), -(row["score"] as Double)) }
        }
    }

    /// Pages matching by their own text or by one of their valid facts, each page once with its
    /// best score. Limit pages after grouping: many matching facts on one page must not hide
    /// other pages. Materialize FTS scores before aggregation (FTS5 auxiliary-function rule).
    public func search(_ terms: [String], type: WikiPageType?, limit: Int) throws -> [(WikiPage, Double)] {
        guard limit > 0, let match = FTSQuery.makeAny(terms: terms) else { return [] }
        return try db.reader.read { d in
            try Row.fetchAll(d, sql: """
                WITH page_matches AS MATERIALIZED (
                    SELECT p.slug, bm25(wiki_pages_fts) AS score
                    FROM wiki_pages_fts JOIN wiki_pages p ON p.id = wiki_pages_fts.rowid
                    WHERE wiki_pages_fts MATCH ? AND (? IS NULL OR p.type = ?)
                ), fact_matches AS MATERIALIZED (
                    SELECT f.slug, bm25(wiki_facts_fts) AS score
                    FROM wiki_facts_fts JOIN wiki_facts f ON f.id = wiki_facts_fts.rowid
                    JOIN wiki_pages p ON p.slug = f.slug
                    WHERE wiki_facts_fts MATCH ? AND f.invalid_at IS NULL AND (? IS NULL OR p.type = ?)
                ), best_matches AS (
                    SELECT slug, MIN(score) AS score FROM (
                        SELECT * FROM page_matches UNION ALL SELECT * FROM fact_matches
                    ) GROUP BY slug
                )
                SELECT p.*, m.score FROM best_matches m JOIN wiki_pages p ON p.slug = m.slug
                ORDER BY m.score, p.last_seen DESC, p.slug LIMIT ?
                """, arguments: [match, type?.rawValue, type?.rawValue,
                                  match, type?.rawValue, type?.rawValue, limit])
                .map { row in (try WikiPage(row: row), -(row["score"] as Double)) }
        }
    }
}
