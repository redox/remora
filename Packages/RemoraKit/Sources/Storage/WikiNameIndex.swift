import Foundation
import GRDB

/// Every wiki page's names (title and aliases), most recently seen first: what entity
/// resolution and mention detection compare against. Load it once per batch (`load(in:)`) and
/// keep it current with `upsert(_:)` after each page insert or update.
public struct WikiNameIndex: Sendable {
    /// How an entity name found its page.
    public enum Match: Sendable, Equatable {
        /// The name equals (folded) the page's title or one of its aliases.
        case name
        /// Only one of the entity's aliases equals a multi-word title or alias of the page.
        case alias
        /// Only `Slug.make(name)` equals the page's slug: no name in common ("C" and "C++").
        case slugCollision
    }

    public struct Entry: Sendable, Equatable {
        public var id: Int64
        public var slug: String
        public var lastSeen: Date
        /// `TextFold.fold` of the title and each alias.
        public var names: Set<String>
        /// `TextFold.key` of the title and each alias (whole-word mention matching).
        public var keys: Set<String>
        /// The folded names of at least two words (alias matching).
        public var multiWordNames: Set<String>

        public init(_ page: WikiPage) {
            id = page.id ?? 0
            slug = page.slug
            lastSeen = page.lastSeen
            let all = [page.title] + page.aliases
            names = Set(all.map(TextFold.fold).filter { !$0.isEmpty })
            keys = Set(all.map { TextFold.key($0) }.filter { !$0.isEmpty })
            multiWordNames = Set(all.filter { TextFold.key($0).split(separator: " ").count >= 2 }.map(TextFold.fold))
        }
    }

    /// Mention matching uses word n-grams up to this length; longer names fall back to a scan.
    static let maxGram = 8

    public private(set) var entries: [Entry] = []
    private var bySlug: [String: Int] = [:]

    public init(_ pages: [WikiPage] = []) {
        entries = pages.map(Entry.init)
        reorder()
    }

    public static func load(in d: Database) throws -> WikiNameIndex {
        WikiNameIndex(try WikiPage.fetchAll(d, sql: "SELECT * FROM wiki_pages"))
    }

    /// Adds or replaces the page's entry, keeping the most-recently-seen order.
    public mutating func upsert(_ page: WikiPage) {
        let entry = Entry(page)
        if let i = bySlug[page.slug] { entries[i] = entry } else { entries.append(entry) }
        reorder()
    }

    private mutating func reorder() {
        entries.sort { ($0.lastSeen, $0.id) > ($1.lastSeen, $1.id) }
        bySlug = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.element.slug, $0.offset) })
    }

    public func entry(slug: String) -> Entry? { bySlug[slug].map { entries[$0] } }

    /// The page an entity refers to, in this order:
    /// 1. by its own name against every title and alias (the page at `Slug.make(name)` first,
    ///    then the most recently seen);
    /// 2. only when the name matches nothing: by one of `aliases` against titles and aliases of
    ///    at least two words (a model's short alias such as "Marc" never merges two people);
    /// 3. a bare slug collision.
    public func resolve(name: String, aliases: [String]) -> (slug: String, match: Match)? {
        let folded = TextFold.fold(name)
        let slug = Slug.make(name)
        let atSlug = slug.isEmpty ? nil : entry(slug: slug)
        if !folded.isEmpty {
            if let atSlug, atSlug.names.contains(folded) { return (atSlug.slug, .name) }
            if let e = entries.first(where: { $0.names.contains(folded) }) { return (e.slug, .name) }
        }
        let wanted = Set(aliases.map(TextFold.fold).filter { !$0.isEmpty })
        if !wanted.isEmpty, let e = entries.first(where: { !$0.multiWordNames.isDisjoint(with: wanted) }) {
            return (e.slug, .alias)
        }
        return atSlug.map { ($0.slug, .slugCollision) }
    }

    /// The slugs of pages whose title or an alias occurs in `text` as whole words (by
    /// `TextFold.key`), most recently seen first, at most `limit`.
    public func mentioned(in text: String, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        let words = TextFold.key(text).split(separator: " ").map(String.init)
        let longest = min(entries.flatMap(\.keys).map { $0.split(separator: " ").count }.max() ?? 0, Self.maxGram)
        var grams = Set<String>()
        if longest > 0 {
            for start in words.indices {
                var gram = ""
                for n in 0..<min(longest, words.count - start) {
                    gram += (n == 0 ? "" : " ") + words[start + n]
                    grams.insert(gram)
                }
            }
        }
        let haystack = " " + words.joined(separator: " ") + " "
        func occurs(_ key: String) -> Bool {
            key.split(separator: " ").count <= Self.maxGram ? grams.contains(key) : haystack.contains(" \(key) ")
        }
        var out: [String] = []
        for e in entries where e.keys.contains(where: occurs) {
            out.append(e.slug)
            if out.count == limit { break }
        }
        return out
    }
}
