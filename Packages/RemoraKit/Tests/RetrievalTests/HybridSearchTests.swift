import Capture
import Embeddings
import Foundation
import Storage
import Testing
@testable import Retrieval

private let allDerived: Set<MemoryScope> = [.chronicle, .wikiPage, .wikiFact]

private func search(_ db: AppDatabase, embedder: (any Embedder)?, policy: CapturePolicy = openPolicy()) -> HybridSearch {
    HybridSearch(db: db, embedder: embedder, index: embedder == nil ? nil : VectorIndex(db: db), policy: { policy })
}

@Test func fusesFTSAndVectorHits() async throws {
    let db = try AppDatabase.inMemory()
    let embedder = HashingEmbedder(dimension: 1_024)
    // A: only the (expanded) FTS term matches; B: only the query's meaning (vector); C: both.
    let a = try seedChronicle(db, key: "A", summary: "Budget review notes")
    let b = try seedChronicle(db, key: "B", summary: "Oslo offsite agenda")
    let c = try seedChronicle(db, key: "C", summary: "Oslo offsite budget")
    try await indexAll(db, embedder)

    let hits = try await search(db, embedder: embedder)
        .search(query: "oslo offsite", terms: ["budget"], scopes: allDerived, limit: 10)
    #expect(hits.first?.id == c.id && hits.first?.scope == .chronicle)
    #expect(Set(hits.map(\.id)) == Set([a.id, b.id, c.id].compactMap { $0 }))
    #expect(hits.map(\.score) == hits.map(\.score).sorted(by: >))
    #expect(hits.first?.title == "C" && hits.first?.snippet == "Oslo offsite budget")
}

@Test func fallsBackToFTSWithoutEmbedder() async throws {
    let db = try AppDatabase.inMemory()
    let a = try seedChronicle(db, key: "A", summary: "Budget review notes")
    _ = try seedChronicle(db, key: "B", summary: "Oslo offsite agenda")
    let c = try seedChronicle(db, key: "C", summary: "Oslo offsite budget")
    try await indexAll(db, HashingEmbedder(dimension: 1_024))

    for embedder in [nil, UnavailableEmbedder() as any Embedder] {
        let hits = try await search(db, embedder: embedder)
            .search(query: "oslo offsite", terms: ["budget"], scopes: allDerived, limit: 10)
        // FTS only: the vector-only row B is not found.
        #expect(Set(hits.map(\.id)) == Set([a.id, c.id].compactMap { $0 }))
    }
}

@Test func invalidatedFactsNeverReturned() async throws {
    let db = try AppDatabase.inMemory()
    let embedder = HashingEmbedder(dimension: 1_024)
    try seedPage(db, slug: "oslo-offsite", title: "Oslo offsite")
    let valid = try seedFact(db, slug: "oslo-offsite", "Budget is 12k")
    let invalid = try seedFact(db, slug: "oslo-offsite", "Budget is 9k", invalid: true)
    try await indexAll(db, embedder)
    // Even a stale vector left for the invalidated fact must not bring it back.
    let identity = try #require(await embedder.identity())
    try EmbeddingStore(db).upsert(owner: .wikiFact, ownerID: try #require(invalid.id), identity: identity,
                                  vector: try await embedder.embed("Oslo offsite: Budget is 9k"), contentHash: "x", at: memNow)

    let hits = try await search(db, embedder: embedder)
        .search(query: "oslo offsite budget", terms: ["budget"], scopes: [.wikiFact], limit: 10)
    #expect(hits.map(\.id) == [valid.id].compactMap { $0 })
    #expect(hits.first?.title == "Oslo offsite" && hits.first?.snippet == "Budget is 12k" && hits.first?.slug == "oslo-offsite")
}

@Test func snapshotHitsArePolicyFiltered() async throws {
    let db = try AppDatabase.inMemory()
    let ok = try seedSnapshot(db, "Roadmap review on Thursday", app: "Mail", title: "Re: roadmap")
    _ = try seedSnapshot(db, "Roadmap secret in Slack", app: "Slack", bundleID: "com.tinyspeck.slackmacgap")
    try ExclusionStore(db).add("app:Slack")

    let hits = try await search(db, embedder: nil, policy: SnapshotPolicy.current(db))
        .search(query: "roadmap", terms: ["roadmap"], scopes: [.snapshot], limit: 10)
    #expect(hits.map(\.id) == [ok.id].compactMap { $0 })
    #expect(hits.first?.title == "Mail — Re: roadmap")
    // Exclusions that cannot be loaded deny everything.
    let none = try await search(db, embedder: nil, policy: .denyAll)
        .search(query: "roadmap", terms: ["roadmap"], scopes: [.snapshot], limit: 10)
    #expect(none.isEmpty)
}

@Test func derivedHitsCitingOnlyExcludedSnapshotsAreDropped() async throws {
    let db = try AppDatabase.inMemory()
    let secret = try seedSnapshot(db, "x", app: "Slack", bundleID: "com.tinyspeck.slackmacgap")
    let fine = try seedSnapshot(db, "y", app: "Mail")
    try ExclusionStore(db).add("app:Slack")
    _ = try seedChronicle(db, key: "excluded", summary: "Roadmap from Slack", snapshotIDs: [try #require(secret.id)])
    let mixed = try seedChronicle(db, key: "mixed", summary: "Roadmap mixed sources",
                                  snapshotIDs: [try #require(secret.id), try #require(fine.id)])
    let orphan = try seedChronicle(db, key: "orphan", summary: "Roadmap from expired evidence", snapshotIDs: [999])

    let hits = try await search(db, embedder: nil, policy: SnapshotPolicy.current(db))
        .search(query: "roadmap", terms: ["roadmap"], scopes: allDerived, limit: 10)
    #expect(Set(hits.map(\.id)) == Set([mixed.id, orphan.id].compactMap { $0 }))
}

@Test func hitsAreTimeFiltered() async throws {
    let db = try AppDatabase.inMemory()
    let old = try seedChronicle(db, key: "old", summary: "Roadmap kickoff", start: memNow.addingTimeInterval(-30 * 86_400))
    let new = try seedChronicle(db, key: "new", summary: "Roadmap review", start: memNow.addingTimeInterval(-7_200))
    let s = search(db, embedder: nil)
    let recent = try await s.search(query: "roadmap", terms: ["roadmap"], scopes: [.chronicle],
                                    since: memNow.addingTimeInterval(-86_400), limit: 10)
    #expect(recent.map(\.id) == [new.id].compactMap { $0 })
    let older = try await s.search(query: "roadmap", terms: ["roadmap"], scopes: [.chronicle],
                                   until: memNow.addingTimeInterval(-86_400), limit: 10)
    #expect(older.map(\.id) == [old.id].compactMap { $0 })
}

@Test func wikiPagesAndFactsAreFusedByRank() async throws {
    // bm25 scores of two FTS tables are not comparable: each scope is its own ranked list (F-16).
    let db = try AppDatabase.inMemory()
    let page = try seedPage(db, slug: "oslo", title: "Oslo offsite", summary: "Team offsite in Oslo")
    let fact = try seedFact(db, slug: "oslo", "The Oslo offsite budget is 12k")
    let hits = try await search(db, embedder: nil)
        .search(query: "oslo", terms: ["oslo"], scopes: [.wikiPage, .wikiFact], limit: 10)
    #expect(hits.count == 2)
    // Both are rank 1 of their own list: equal RRF scores.
    #expect(hits[0].score == hits[1].score && hits[0].score == 1 / (RRF.k + 1))
    #expect(Set(hits.map(\.id)) == Set([page.id, fact.id].compactMap { $0 }))
}

@Test func factHitsFollowTheirPage() async throws {
    // A page dropped by DerivedPolicy takes its facts with it: its title never reaches <memory>.
    let db = try AppDatabase.inMemory()
    let secret = try seedSnapshot(db, "x", app: "Slack", bundleID: "com.tinyspeck.slackmacgap")
    try ExclusionStore(db).add("app:Slack")
    try seedPage(db, slug: "secret-project", title: "Secret project", snapshotIDs: [try #require(secret.id)])
    try seedFact(db, slug: "secret-project", "Roadmap due in March")
    try seedPage(db, slug: "open-project", title: "Open project")
    let visible = try seedFact(db, slug: "open-project", "Roadmap due in April")
    let policy = SnapshotPolicy.current(db)
    let hits = try await search(db, embedder: nil, policy: policy)
        .search(query: "roadmap", terms: ["roadmap"], scopes: [.wikiPage, .wikiFact], limit: 10)
    #expect(hits.map(\.id) == [visible.id].compactMap { $0 })
    #expect(!hits.contains { $0.title.contains("Secret") })
}

@Test func searchUsesTheCallersPolicyWhenGiven() async throws {
    let db = try AppDatabase.inMemory()
    let s = try seedSnapshot(db, "Roadmap review", app: "Mail")
    // The initializer's policy denies everything; the request's own policy wins.
    let hybrid = HybridSearch(db: db, embedder: nil, index: nil, policy: { .denyAll })
    let hits = try await hybrid.search(query: "roadmap", terms: ["roadmap"], scopes: [.snapshot], limit: 5,
                                       policy: openPolicy())
    #expect(hits.map(\.id) == [s.id].compactMap { $0 })
}

/// Final review #4: an app excluded after retention deleted its snapshots still hides what was
/// learned from it (judged from the tombstones); a row whose snapshots were deleted from an app
/// still allowed stays.
@Test func chronicleOfAnAppExcludedAfterRetentionStaysHiddenInRewriteHits() async throws {
    let db = try AppDatabase.inMemory()
    let secret = try #require(try seedSnapshot(db, "x", app: "Slack", bundleID: "com.tinyspeck.slackmacgap").id)
    let fine = try #require(try seedSnapshot(db, "y", app: "Mail").id)
    _ = try seedChronicle(db, key: "slack", summary: "Roadmap from Slack", snapshotIDs: [secret])
    let mail = try seedChronicle(db, key: "mail", summary: "Roadmap from Mail", snapshotIDs: [fine])
    // Retention deletes both snapshots, then (day 10 after) Slack is excluded.
    try await db.writer.write { _ = try RetentionStore.deleteUnsummarisable([secret, fine], in: $0) }
    try ExclusionStore(db).add("app:Slack")

    let hits = try await search(db, embedder: nil, policy: SnapshotPolicy.current(db))
        .search(query: "roadmap", terms: ["roadmap"], scopes: allDerived, limit: 10)
    #expect(hits.map(\.id) == [mail.id].compactMap { $0 })
}

/// Final review #5 (M1): under `.denyAll`, `DerivedPolicy` keeps nothing, not even rows citing no
/// snapshot (week rows) or only deleted ones; with loadable exclusions both are kept.
@Test func derivedPolicyFailsClosedUnderDenyAll() throws {
    let db = try AppDatabase.inMemory()
    let week = try seedChronicle(db, key: "2027-W02", summary: "Week", level: .week)
    let orphan = try seedChronicle(db, key: "orphan", summary: "Gone", snapshotIDs: [999])
    let (denied, deniedLive, deniedIDs, open) = try db.reader.read { d in
        (try DerivedPolicy.filter([week, orphan], ids: \.snapshotIDs, policy: .denyAll, in: d),
         try DerivedPolicy.requiringLiveEvidence([week], ids: \.snapshotIDs, policy: .denyAll, in: d),
         try DerivedPolicy.allowedIDs([999], policy: .denyAll, in: d),
         try DerivedPolicy.filter([week, orphan], ids: \.snapshotIDs, policy: openPolicy(), in: d))
    }
    #expect(denied.isEmpty && deniedLive.isEmpty && deniedIDs.isEmpty)
    #expect(open.count == 2)
}

/// Residual round #1: tombstones may only deny. Rule: a row stays when it cites no judged snapshot
/// (judged = live, or tombstoned and denied) or at least one live allowed snapshot.
@Test func tombstonesOnlyEverDeny() throws {
    let db = try AppDatabase.inMemory()
    let liveSlack = try #require(try seedSnapshot(db, "a", app: "Slack").id)
    let liveMail = try #require(try seedSnapshot(db, "b", app: "Mail").id)
    let goneMail = try #require(try seedSnapshot(db, "c", app: "Mail").id)
    let goneSlack = try #require(try seedSnapshot(db, "d", app: "Slack").id)
    // A title rule a tombstone cannot see: the tombstone of goneTitled passes, but it must not allow.
    let goneTitled = try #require(try seedSnapshot(db, "e", app: "Notes", title: "Payroll").id)
    try db.writer.write { _ = try RetentionStore.deleteUnsummarisable([goneMail, goneSlack, goneTitled], in: $0) }
    try ExclusionStore(db).add("app:Slack")
    try ExclusionStore(db).add("title:Payroll")
    let policy = SnapshotPolicy.current(db)
    func kept(_ ids: [Int64]) throws -> Bool {
        let row = try seedChronicle(db, key: UUID().uuidString, summary: "row", snapshotIDs: ids)
        return try db.reader.read { !(try DerivedPolicy.filter([row], ids: \.snapshotIDs, policy: policy, in: $0)).isEmpty }
    }
    #expect(try !kept([liveSlack, goneMail]))      // live excluded + tombstoned allowed: hidden (was shown)
    #expect(try !kept([liveSlack, goneTitled]))    // a passing tombstone never allows
    #expect(try !kept([goneSlack]))                // tombstoned denied: hidden after retention
    #expect(try kept([liveMail, goneSlack]))       // live allowed + tombstoned denied: as before tombstones
    #expect(try !kept([liveSlack]))                // live excluded only: hidden, as before
    #expect(try kept([goneMail]))                  // all gone, no denying tombstone: F-59, kept
    #expect(try kept([goneTitled, 99_999]))        // same, plus a forgotten id
}
