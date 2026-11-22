import Foundation
import GRDB
import Testing
import Storage
@testable import Embeddings

@Test func indexerEmbedsThenSkipsUnchangedThenReembedsOnEdit() async throws {
    let db = try AppDatabase.inMemory()
    let s = try seed(db)
    let indexer = EmbeddingIndexer(db: db, embedder: HashingEmbedder())
    #expect(try await indexer.pendingCount() == 3)
    #expect(try await indexer.run(at: t0.addingTimeInterval(10), generation: 0) == 3)
    #expect(try count(db) == 3)
    #expect(try await indexer.pendingCount() == 0)
    #expect(try await indexer.run(at: t0.addingTimeInterval(20), generation: 0) == 0)
    try exec(db, "UPDATE wiki_pages SET summary = ?, updated_at = ? WHERE id = ?", ["Different summary entirely", t0.addingTimeInterval(30), s.pageID])
    #expect(try await indexer.pendingCount() == 2)  // the page and (by title) its fact
    #expect(try await indexer.run(at: t0.addingTimeInterval(40), generation: 0) == 1)
    #expect(try await indexer.pendingCount() == 0)
}

@Test func touchedSourceWithSameTextIsNotReembedded() async throws {
    let db = try AppDatabase.inMemory()
    let s = try seed(db)
    let indexer = EmbeddingIndexer(db: db, embedder: HashingEmbedder())
    _ = try await indexer.run(at: t0.addingTimeInterval(10), generation: 0)
    try exec(db, "UPDATE wiki_facts SET last_confirmed_at = ? WHERE id = ?", [t0.addingTimeInterval(30), s.factID])
    #expect(try await indexer.pendingCount() == 1)
    #expect(try await indexer.run(at: t0.addingTimeInterval(40), generation: 0) == 0)
    #expect(try await indexer.pendingCount() == 0)
}

@Test func sourceTextFollowsTheSpec() throws {
    let db = try AppDatabase.inMemory()
    _ = try seed(db)
    let sources = try db.reader.read { try EmbeddingIndexer.sources($0) }
    #expect(sources.map(\.owner) == [.chronicle, .wikiPage, .wikiFact])
    #expect(sources[0].text == "Budget meeting in Oslo with Ingrid")
    #expect(sources[1].text == "Oslo trip\nTravel planning for Oslo\nFlights and hotel")
    #expect(sources[2].text == "Oslo trip: Hotel booked near the harbour")
    #expect(sources[0].hash.count == 64)
}

@Test func revisionChangeMakesEverythingPending() async throws {
    let db = try AppDatabase.inMemory()
    _ = try seed(db)
    _ = try await EmbeddingIndexer(db: db, embedder: HashingEmbedder(revision: 1)).run(at: t0.addingTimeInterval(10), generation: 0)
    let v2 = EmbeddingIndexer(db: db, embedder: HashingEmbedder(revision: 2))
    #expect(try await v2.pendingCount() == 3)
    #expect(try await v2.run(at: t0.addingTimeInterval(20), generation: 0) == 3)
    #expect(try await v2.pendingCount() == 0)
}

@Test func invalidatedFactLosesEmbedding() async throws {
    let db = try AppDatabase.inMemory()
    let s = try seed(db)
    let indexer = EmbeddingIndexer(db: db, embedder: HashingEmbedder())
    _ = try await indexer.run(at: t0.addingTimeInterval(10), generation: 0)
    try exec(db, "UPDATE wiki_facts SET invalid_at = ? WHERE id = ?", [t0.addingTimeInterval(20), s.factID])
    #expect(try await indexer.run(at: t0.addingTimeInterval(30), generation: 0) == 0)
    #expect(try count(db) == 2)
    let owners = try ownerTables(db)
    #expect(owners == ["chronicle", "wiki_pages"])
}

@Test func deletedOwnerLosesEmbedding() async throws {
    let db = try AppDatabase.inMemory()
    let s = try seed(db)
    let indexer = EmbeddingIndexer(db: db, embedder: HashingEmbedder())
    _ = try await indexer.run(at: t0.addingTimeInterval(10), generation: 0)
    try exec(db, "DELETE FROM chronicle WHERE id = ?", [s.chronicleID])
    _ = try await indexer.run(at: t0.addingTimeInterval(20), generation: 0)
    #expect(try count(db) == 2)
}

@Test func runLimitBoundsTheBatch() async throws {
    let db = try AppDatabase.inMemory()
    _ = try seed(db)
    let indexer = EmbeddingIndexer(db: db, embedder: HashingEmbedder())
    #expect(try await indexer.run(limit: 2, at: t0.addingTimeInterval(10), generation: 0) == 2)
    #expect(try await indexer.pendingCount() == 1)
}

@Test func unavailableEmbedderWritesNothing() async throws {
    struct Down: Embedder {
        func identity() async -> EmbedderIdentity? { nil }
        func embed(_ text: String) async throws -> [Float] { throw EmbeddingError.unavailable }
    }
    let db = try AppDatabase.inMemory()
    _ = try seed(db)
    #expect(try await EmbeddingIndexer(db: db, embedder: Down()).run(at: t0, generation: 0) == 0)
    #expect(try count(db) == 0)
}

@Test func runStraddlingDeleteAllWritesNothing() async throws {
    let db = try AppDatabase.inMemory()
    _ = try seed(db)
    let generation = try DataGeneration.current(db)
    let embedder = HookEmbedder()
    embedder.onEmbed = { try DataReset.deleteAllCapturedData(in: db) }
    let indexer = EmbeddingIndexer(db: db, embedder: embedder)
    await #expect(throws: DataGeneration.Stale.self) {
        _ = try await indexer.run(at: t0.addingTimeInterval(10), generation: generation)
    }
    #expect(try count(db) == 0)
    #expect(try count(db, "chronicle") == 0)
}

@Test func runWithAnOldGenerationWritesNothing() async throws {
    let db = try AppDatabase.inMemory()
    _ = try seed(db)
    try DataReset.deleteAllCapturedData(in: db)
    _ = try seed(db)
    let indexer = EmbeddingIndexer(db: db, embedder: HashingEmbedder())
    await #expect(throws: DataGeneration.Stale.self) { _ = try await indexer.run(at: t0, generation: 0) }
    #expect(try count(db) == 0)
}

@Test func renamingAPageReembedsItsFactsWithTheNewTitle() async throws {
    let db = try AppDatabase.inMemory()
    let s = try seed(db)
    let indexer = EmbeddingIndexer(db: db, embedder: HashingEmbedder())
    _ = try await indexer.run(at: t0.addingTimeInterval(10), generation: 0)
    try exec(db, "UPDATE wiki_pages SET title = ?, updated_at = ? WHERE id = ?", ["Bergen trip", t0.addingTimeInterval(30), s.pageID])
    #expect(try await indexer.pendingCount() == 2)  // the page and its fact
    #expect(try await indexer.run(at: t0.addingTimeInterval(40), generation: 0) == 2)
    #expect(try await indexer.pendingCount() == 0)
    let stored = try storedHash(db, "wiki_facts", s.factID)
    let expected = try factSourceHash(db)
    #expect(stored == expected)
}

@Test func bodyOnlyPageChangeTouchesFactsWithoutReembedding() async throws {
    let db = try AppDatabase.inMemory()
    let s = try seed(db)
    let indexer = EmbeddingIndexer(db: db, embedder: HashingEmbedder())
    _ = try await indexer.run(at: t0.addingTimeInterval(10), generation: 0)
    let before = try storedHash(db, "wiki_facts", s.factID)
    try exec(db, "UPDATE wiki_pages SET body = ?, updated_at = ? WHERE id = ?", ["New body text", t0.addingTimeInterval(30), s.pageID])
    #expect(try await indexer.pendingCount() == 2)
    #expect(try await indexer.run(at: t0.addingTimeInterval(40), generation: 0) == 1)  // page only
    #expect(try await indexer.pendingCount() == 0)
    #expect(try storedHash(db, "wiki_facts", s.factID) == before)
}

@Test func unembeddableRowsDoNotStarveTheBatch() async throws {
    let db = try AppDatabase.inMemory()
    try seedUnembeddable(db)
    let e = HashingEmbedder()
    let indexer = EmbeddingIndexer(db: db, embedder: e)
    var written = 0
    var rounds = 0
    while try await indexer.pendingCount() > 0, rounds < 10 {
        written += try await indexer.run(limit: 200, at: t0.addingTimeInterval(Double(10 + rounds)), generation: 0)
        rounds += 1
    }
    #expect(written == 1)
    #expect(try await indexer.pendingCount() == 0)
    let id = try #require(await e.identity())
    let hits = try await VectorIndex(db: db).search(try await e.embed("Oslo"), identity: id, owners: [.chronicle], limit: 5)
    #expect(hits.count == 1)
}

@Test func orphansAreRemovedEvenWhenTheEmbedderIsUnavailable() async throws {
    struct Down: Embedder {
        func identity() async -> EmbedderIdentity? { nil }
        func embed(_ text: String) async throws -> [Float] { throw EmbeddingError.unavailable }
    }
    let db = try AppDatabase.inMemory()
    let s = try seed(db)
    _ = try await EmbeddingIndexer(db: db, embedder: HashingEmbedder()).run(at: t0.addingTimeInterval(10), generation: 0)
    try exec(db, "UPDATE wiki_facts SET invalid_at = ? WHERE id = ?", [t0.addingTimeInterval(20), s.factID])
    try exec(db, "DELETE FROM chronicle WHERE id = ?", [s.chronicleID])
    #expect(try await EmbeddingIndexer(db: db, embedder: Down()).run(at: t0.addingTimeInterval(30), generation: 0) == 0)
    #expect(try ownerTables(db) == ["wiki_pages"])
}

@Test func deletingAPageCascadesItsFactsSoNoFactWithoutAPageExists() async throws {
    let db = try AppDatabase.inMemory()
    let s = try seed(db)
    _ = try await EmbeddingIndexer(db: db, embedder: HashingEmbedder()).run(at: t0.addingTimeInterval(10), generation: 0)
    try exec(db, "DELETE FROM wiki_pages WHERE id = ?", [s.pageID])
    let facts = try count(db, "wiki_facts")
    #expect(facts == 0)
    _ = try await EmbeddingIndexer(db: db, embedder: HashingEmbedder()).run(at: t0.addingTimeInterval(20), generation: 0)
    #expect(try ownerTables(db) == ["chronicle"])
}
