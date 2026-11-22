import Foundation
import GRDB
import Testing
@testable import Storage

private let base = Date(timeIntervalSince1970: 1_763_643_600)  // 2025-11-20 13:00 UTC

private func page(_ slug: String, _ type: WikiPageType = .person, title: String, aliases: [String] = [],
                  summary: String = "", mentions: Int = 1, lastSeen: TimeInterval = 0, dirty: Bool = false) -> WikiPage {
    WikiPage(slug: slug, type: type, title: title, aliases: aliases, summary: summary, mentionCount: mentions,
             firstSeen: base, lastSeen: base.addingTimeInterval(lastSeen), isDirty: dirty, updatedAt: base)
}

private func fact(_ slug: String, _ text: String, invalid: Bool = false) -> WikiFact {
    WikiFact(slug: slug, fact: text, normKey: TextFold.key(text), subject: .world, basis: .onScreenContent,
             worth: .core, validAt: base, invalidAt: invalid ? base.addingTimeInterval(60) : nil,
             recordedAt: base, lastConfirmedAt: base)
}

@discardableResult
private func seed(_ db: AppDatabase, pages: [WikiPage], facts: [WikiFact] = []) throws -> [WikiFact] {
    try db.writer.write { d in
        for p in pages { _ = try WikiStore.insert(p, in: d) }
        return try facts.map { try WikiStore.insert($0, in: d) }
    }
}

@Test(arguments: [("Réunion d'équipe", "reunion-d-equipe"), ("  Marc  Dupont ", "marc-dupont"), ("C++", "c"),
                  ("Œuvre « Ça va » !", "oeuvre-ca-va"), ("+++", "")])
func slugs(name: String, slug: String) { #expect(Slug.make(name) == slug) }

@Test func slugIsAtMostSixtyCharactersWithoutTrailingDash() {
    let s = Slug.make(String(repeating: "abcdefghi ", count: 10))
    #expect(s.count <= 60 && !s.hasSuffix("-") && s.hasPrefix("abcdefghi-abcdefghi"))
}

@Test func keyFoldsCasePunctuationAndAccents() {
    #expect(TextFold.key("  L'offsite d’Oslo — 12k€ !") == "l offsite d oslo 12k")
    #expect(TextFold.key("Budget: 12 000") == TextFold.key("budget 12 000"))
    #expect(TextFold.key("C++") == TextFold.key("C"))
}

@Test func factKeysKeepValueSymbols() {
    func k(_ s: String) -> String { TextFold.key(s, keepingSymbols: true) }
    #expect(k("Uses C") != k("Uses C++") && k("Uses C#") != k("Uses C++"))
    #expect(k("Budget is 12k$") != k("Budget is 12k€"))
    #expect(k("Revenue -5%") != k("Revenue 5%") && k("Revenue 5%") != k("Revenue 5"))
    #expect(k("Le budget : 12k€ !") == k("le BUDGET 12k€") && k("C++") == "c + +")
}

@Test func nameIndexResolvesByNameThenMultiWordAliasThenSlug() {
    func p(_ slug: String, _ title: String, _ aliases: [String] = [], seen: TimeInterval) -> WikiPage {
        var page = WikiPage(slug: slug, type: .person, title: title, aliases: aliases, firstSeen: base,
                            lastSeen: base.addingTimeInterval(seen), updatedAt: base)
        page.id = Int64(seen)
        return page
    }
    let index = WikiNameIndex([p("marc-dupont", "Marc Dupont", ["Marc"], seen: 1),
                               p("marc-levy", "Marc Levy", ["Marc"], seen: 2), p("c", "C++", seen: 3)])
    #expect(index.resolve(name: "marc", aliases: [])! == ("marc-levy", .name))
    #expect(index.resolve(name: "Marc Martin", aliases: ["Marc"]) == nil)
    #expect(index.resolve(name: "M. Dupont", aliases: ["marc dupont"])! == ("marc-dupont", .alias))
    #expect(index.resolve(name: "C", aliases: [])! == ("c", .slugCollision))
}

@Test func resolvesByAliasAcrossAccents() throws {
    let db = try AppDatabase.inMemory()
    try seed(db, pages: [page("elodie-martin", title: "Élodie Martin", aliases: ["Elodie"]),
                         page("marc-dupont", title: "Marc Dupont")])
    let store = WikiStore(db)
    let found = try db.reader.read { try store.resolve(name: "elodie", aliases: [], in: $0) }
    #expect(found?.slug == "elodie-martin")
    // By slug, by folded title, and by one of the given aliases.
    #expect(try db.reader.read { try store.resolve(name: "MARC DUPONT", aliases: [], in: $0) }?.slug == "marc-dupont")
    #expect(try db.reader.read { try store.resolve(name: "Élodie M.", aliases: ["ÉLODIE MARTIN"], in: $0) }?.slug
            == "elodie-martin")
    // A one-word alias from the model never resolves on its own.
    #expect(try db.reader.read { try store.resolve(name: "Élodie M.", aliases: ["ÉLODIE"], in: $0) } == nil)
    #expect(try db.reader.read { try store.resolve(name: "Léa", aliases: ["Lea B"], in: $0) } == nil)
}

@Test func resolvePrefersTheSameNameOverASlugCollision() throws {
    let db = try AppDatabase.inMemory()
    // "C++" holds slug "c"; the "C" language page was numbered.
    try seed(db, pages: [page("c", .tool, title: "C++"), page("c-2", .topic, title: "C")])
    let found = try db.reader.read { try WikiStore(db).resolve(name: "C", aliases: [], in: $0) }
    #expect(found?.slug == "c-2")
}

@Test func knownListsMostRecentlySeenPagesFirst() throws {
    let db = try AppDatabase.inMemory()
    try seed(db, pages: (0..<5).map { page("p\($0)", title: "P\($0)", lastSeen: Double($0) * 60) })
    let known = try WikiStore(db).known(limit: 3)
    #expect(known.map(\.slug) == ["p4", "p3", "p2"])
    #expect(try WikiStore(db).known().count == 5)
}

@Test func factsHideInvalidUnlessAsked() throws {
    let db = try AppDatabase.inMemory()
    try seed(db, pages: [page("oslo-offsite", .project, title: "Oslo offsite")],
             facts: [fact("oslo-offsite", "Budget is 12k€", invalid: true), fact("oslo-offsite", "Budget is 15k€")])
    let store = WikiStore(db)
    #expect(try store.validFacts(slug: "oslo-offsite").map(\.fact) == ["Budget is 15k€"])
    #expect(try store.facts(slug: "oslo-offsite", includeInvalid: true).map(\.fact).sorted()
            == ["Budget is 12k€", "Budget is 15k€"])
    #expect(try store.facts(slug: "oslo-offsite", includeInvalid: false).count == 1)
}

@Test func listFiltersByTypeAndSorts() throws {
    let db = try AppDatabase.inMemory()
    try seed(db, pages: [page("a", .person, title: "A", mentions: 9, lastSeen: 0),
                         page("b", .person, title: "B", mentions: 1, lastSeen: 600),
                         page("c", .project, title: "C", mentions: 5, lastSeen: 300)])
    let store = WikiStore(db)
    #expect(try store.list(type: nil, sort: .recent, limit: 10, offset: 0).map(\.slug) == ["b", "c", "a"])
    #expect(try store.list(type: nil, sort: .mentions, limit: 10, offset: 0).map(\.slug) == ["a", "c", "b"])
    #expect(try store.list(type: .person, sort: .mentions, limit: 10, offset: 0).map(\.slug) == ["a", "b"])
    #expect(try store.list(type: nil, sort: .recent, limit: 1, offset: 1).map(\.slug) == ["c"])
}

@Test func searchPagesAndFactsSeparatelyAndComposed() throws {
    let db = try AppDatabase.inMemory()
    try seed(db, pages: [page("oslo-offsite", .project, title: "Oslo offsite", summary: "Team trip"),
                         page("marc-dupont", .person, title: "Marc Dupont"),
                         page("acme", .org, title: "Acme")],
             facts: [fact("marc-dupont", "Marc organises the Réunion in Oslo"),
                     fact("acme", "Acme moved its offsite to Oslo", invalid: true)])
    let store = WikiStore(db)
    // Accent-insensitive, prefix-matching, bm25 (higher is better).
    let pages = try store.searchPages(["oslo"], type: nil, limit: 10)
    #expect(pages.map(\.0.slug) == ["oslo-offsite"])
    let facts = try store.searchFacts(["reunion"], type: nil, limit: 10)
    #expect(facts.map(\.0.slug) == ["marc-dupont"])
    // Invalid facts never match.
    #expect(try store.searchFacts(["moved"], type: nil, limit: 10).isEmpty)
    let both = try store.search(["oslo"], type: nil, limit: 10)
    #expect(Set(both.map(\.0.slug)) == ["oslo-offsite", "marc-dupont"])
    #expect(both.map(\.1) == both.map(\.1).sorted(by: >))
    #expect(try store.search(["oslo"], type: .person, limit: 10).map(\.0.slug) == ["marc-dupont"])
    #expect(try store.searchFacts(["oslo"], type: .project, limit: 10).isEmpty)
    #expect(try store.search([], type: nil, limit: 10).isEmpty)
}

@Test func dirtyPagesNeedEnoughMentions() throws {
    let db = try AppDatabase.inMemory()
    try seed(db, pages: [page("a", title: "A", mentions: 1, dirty: true), page("b", title: "B", mentions: 4, dirty: true),
                         page("c", title: "C", mentions: 2, dirty: true), page("d", title: "D", mentions: 9)])
    #expect(try WikiStore(db).dirtyPages(minMentions: 2, limit: 8).map(\.slug) == ["b", "c"])
    #expect(try WikiStore(db).dirtyPages(minMentions: 2, limit: 1).map(\.slug) == ["b"])
}

@Test func deleteRemovesThePageItsFactsAndTheirVectors() throws {
    let db = try AppDatabase.inMemory()
    let facts = try seed(db, pages: [page("a", title: "A"), page("b", title: "B")],
                         facts: [fact("a", "A fact"), fact("b", "B fact")])
    let pageID = try #require(try WikiStore(db).page(slug: "a")?.id)
    try db.writer.write { d in
        for (owner, id) in [("wiki_pages", pageID), ("wiki_facts", facts[0].id!), ("wiki_facts", facts[1].id!)] {
            var v = EmbeddingRecord(ownerTable: owner, ownerID: id, modelID: "m", revision: 1, dims: 1,
                                    vector: Data([0, 0, 128, 63]), contentHash: "h", createdAt: base)
            try v.insert(d)
        }
    }
    try WikiStore(db).delete(slug: "a")
    #expect(try WikiStore(db).page(slug: "a") == nil)
    #expect(try WikiStore(db).facts(slug: "a", includeInvalid: true).isEmpty)
    #expect(try WikiStore(db).validFacts(slug: "b").count == 1)
    let owners = try db.reader.read { try Row.fetchAll($0, sql: "SELECT owner_table, owner_id FROM embeddings") }
    #expect(owners.count == 1 && owners[0]["owner_id"] as Int64 == facts[1].id!)
}

@Test func mentionedPagesMatchWholeWordsOnly() throws {
    let db = try AppDatabase.inMemory()
    try seed(db, pages: [page("oslo-offsite", .project, title: "Oslo offsite", lastSeen: 0),
                         page("elodie-martin", title: "Élodie Martin", aliases: ["Elodie"], lastSeen: 60),
                         page("ai", .topic, title: "AI", lastSeen: 120),
                         page("acme", .org, title: "Acme", lastSeen: 180)])
    let text = "Budget de l'OSLO   Offsite validé par elodie. Said: maintenant."
    let found = try db.reader.read { try WikiStore.mentionedPages(in: text, limit: 60, in: $0) }
    // "ai" occurs only inside "maintenant": not a mention. Newest first.
    #expect(found.map(\.slug) == ["elodie-martin", "oslo-offsite"])
    #expect(try db.reader.read { try WikiStore.mentionedPages(in: text, limit: 1, in: $0) }.map(\.slug)
            == ["elodie-martin"])
}

@Test func mentionedPagesFindNamesLongerThanTheNGramCap() throws {
    let db = try AppDatabase.inMemory()
    let long = "The Very Long Name Of A Project With Nine Words"
    try seed(db, pages: [page("long", .project, title: long), page("short", .project, title: "Name Of")])
    let found = try db.reader.read {
        try WikiStore.mentionedPages(in: "Notes about the very long name of a project with nine words.", limit: 10, in: $0)
    }
    #expect(Set(found.map(\.slug)) == ["long", "short"])
    #expect(try db.reader.read { try WikiStore.mentionedPages(in: "the very long name", limit: 10, in: $0) }.isEmpty)
}
