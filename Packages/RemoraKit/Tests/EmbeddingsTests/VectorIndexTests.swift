import Foundation
import Testing
import Storage
@testable import Embeddings

private func indexed(revision: Int = 1) async throws -> (AppDatabase, Seeded, HashingEmbedder) {
    let db = try AppDatabase.inMemory()
    let s = try seed(db)
    let e = HashingEmbedder(revision: revision)
    _ = try await EmbeddingIndexer(db: db, embedder: e).run(at: t0.addingTimeInterval(10), generation: 0)
    return (db, s, e)
}

@Test func searchRanksNearestFirst() async throws {
    let (db, s, e) = try await indexed()
    let id = try #require(await e.identity())
    let q = try await e.embed("budget Oslo")
    let hits = try await VectorIndex(db: db).search(q, identity: id, owners: Set(EmbeddingOwner.allCases), limit: 3)
    #expect(hits.first?.owner == .chronicle)
    #expect(hits.first?.id == s.chronicleID)
    #expect(hits.map(\.score) == hits.map(\.score).sorted(by: >))
}

@Test func searchHonoursOwnersAndLimit() async throws {
    let (db, _, e) = try await indexed()
    let id = try #require(await e.identity())
    let q = try await e.embed("Oslo")
    let index = VectorIndex(db: db)
    #expect(try await index.search(q, identity: id, owners: [.wikiFact], limit: 5).map(\.owner) == [.wikiFact])
    #expect(try await index.search(q, identity: id, owners: Set(EmbeddingOwner.allCases), limit: 1).count == 1)
}

@Test func staleRevisionExcludedFromVectorSearch() async throws {
    let (db, _, _) = try await indexed(revision: 1)
    let v2 = HashingEmbedder(revision: 2)
    let id = try #require(await v2.identity())
    let q = try await v2.embed("budget Oslo")
    #expect(try await VectorIndex(db: db).search(q, identity: id, owners: Set(EmbeddingOwner.allCases), limit: 5).isEmpty)
}

@Test func searchSeesNewVectorsAfterTheFingerprintChanges() async throws {
    let (db, s, e) = try await indexed()
    let id = try #require(await e.identity())
    let index = VectorIndex(db: db)
    let q = try await e.embed("quarterly planning")
    #expect(try await index.search(q, identity: id, owners: [.chronicle], limit: 5).count == 1)
    try addChronicle(db, "Quarterly planning review")
    _ = try await EmbeddingIndexer(db: db, embedder: e).run(at: t0.addingTimeInterval(60), generation: 0)
    let hits = try await index.search(q, identity: id, owners: [.chronicle], limit: 5)
    #expect(hits.count == 2)
    #expect(hits.first?.id != s.chronicleID)
}

private func addChronicle(_ db: AppDatabase, _ summary: String) throws {
    try db.writer.write { d in
        var c = Chronicle(level: .hour, periodKey: "2026-11-20T11", periodStart: t0, periodEnd: t0,
                          summary: summary, generatedAt: t0.addingTimeInterval(50))
        try c.insert(d)
    }
}
