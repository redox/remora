import Foundation
import GRDB
import Testing
@testable import Storage

private let t0 = Date(timeIntervalSince1970: 1_763_643_600)
private let later = t0.addingTimeInterval(3_600)

private func seed(_ db: AppDatabase) throws -> (a: [WikiFact], b: [WikiFact]) {
    try db.writer.write { d in
        for (slug, title) in [("anna", "Anna"), ("bob", "Bob")] {
            _ = try WikiStore.insert(WikiPage(slug: slug, type: .person, title: title, mentionCount: 1, firstSeen: t0,
                                              lastSeen: t0, isDirty: false, updatedAt: t0), in: d)
        }
        func fact(_ slug: String, _ text: String, ids: [Int64] = [], invalid: Bool = false) throws -> WikiFact {
            try WikiStore.insert(WikiFact(slug: slug, fact: text, normKey: TextFold.key(text), subject: .thirdParty,
                                          basis: .onScreenContent, worth: .detail, snapshotIDs: ids, validAt: t0,
                                          invalidAt: invalid ? t0 : nil, recordedAt: t0, lastConfirmedAt: t0), in: d)
        }
        let a = [try fact("anna", "Anna lives in Paris"), try fact("anna", "Anna works at Acme"),
                 try fact("anna", "Anna lived in Rome", invalid: true)]
        let b = [try fact("bob", "Bob lives in Lyon")]
        return (a, b)
    }
}

@Suite struct WikiUserFactTests {
    @Test func unknownSlugThrowsNotFound() throws {
        let db = try AppDatabase.inMemory()
        _ = try seed(db)
        #expect(throws: WikiStore.NotFound.self) {
            try WikiStore(db).addUserFact(slug: "nobody", text: "Lives in Oslo", invalidating: [], at: later)
        }
    }

    @Test func invalidatesOnlyThatPagesValidFacts() throws {
        let db = try AppDatabase.inMemory()
        let (a, b) = try seed(db)
        let store = WikiStore(db)
        // Another page's fact, an already-invalid fact and an unknown id are all refused, and
        // nothing is written (one transaction).
        for bad in [b[0].id!, a[2].id!, 9_999] {
            #expect(throws: WikiStore.InvalidFact(bad)) {
                try store.addUserFact(slug: "anna", text: "Anna lives in Lyon", invalidating: [a[0].id!, bad], at: later)
            }
        }
        #expect(try store.validFacts(slug: "anna").map(\.id) == [a[0].id, a[1].id])
        #expect(try store.page(slug: "anna")?.isDirty == false)
        #expect(try store.validFacts(slug: "bob").map(\.id) == [b[0].id])
    }

    @Test func addsAUserStatedFactAndSupersedes() throws {
        let db = try AppDatabase.inMemory()
        let (a, _) = try seed(db)
        let store = WikiStore(db)
        let added = try store.addUserFact(slug: "anna", text: "  Anna lives in Lyon ", invalidating: [a[0].id!], at: later)
        #expect(added.fact == "Anna lives in Lyon")
        #expect(added.subject == .user)
        #expect(added.basis == .userStated)
        #expect(added.worth == .core)
        #expect(added.snapshotIDs.isEmpty)
        #expect(added.llmCallID == nil)
        #expect(added.validAt == later)

        let all = try store.facts(slug: "anna", includeInvalid: true)
        let old = try #require(all.first { $0.id == a[0].id })
        #expect(old.invalidAt == later)
        #expect(old.supersededBy == added.id)
        #expect(all.first { $0.id == a[1].id }?.invalidAt == nil)
        let page = try #require(try store.page(slug: "anna"))
        #expect(page.isDirty)
        #expect(page.mentionCount >= WikiStore.minRewriteMentions)
    }

    @Test func restatingAnExistingFactMakesItUserStated() throws {
        let db = try AppDatabase.inMemory()
        let (a, _) = try seed(db)
        let store = WikiStore(db)
        // "Anna lived in Rome" exists (invalid, from a capture): the user says it is true.
        let added = try store.addUserFact(slug: "anna", text: "Anna lived in Rome", invalidating: [], at: later)
        #expect(added.id == a[2].id)
        #expect(added.invalidAt == nil && added.supersededBy == nil)
        #expect(added.basis == .userStated && added.subject == .user && added.snapshotIDs.isEmpty)
        #expect(try store.facts(slug: "anna", includeInvalid: true).count == 3)
    }

    @Test func emptyTextIsRefused() throws {
        let db = try AppDatabase.inMemory()
        _ = try seed(db)
        #expect(throws: WikiStore.EmptyFact.self) {
            try WikiStore(db).addUserFact(slug: "anna", text: " \n", invalidating: [], at: later)
        }
    }
}
