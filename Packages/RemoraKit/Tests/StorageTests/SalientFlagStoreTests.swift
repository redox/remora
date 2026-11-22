import Foundation
import GRDB
import Testing
@testable import Storage

private let base = Date(timeIntervalSince1970: 1_763_643_600)  // 2025-11-20 13:00 UTC

private func flag(_ kind: FlagKind = .commitment, _ text: String = "Send Marc the deck", person: String = "Marc",
                  due: TimeInterval? = nil, ids: [Int64] = [1], seen: TimeInterval = 0) -> SalientFlag {
    SalientFlag(kind: kind, text: text, owner: .user, person: person, dueAt: due.map { base.addingTimeInterval($0) },
                quote: "je t'envoie le deck", snapshotIDs: ids, periodKey: "2025-11-20T14+0100",
                dedupeKey: SalientFlagStore.dedupeKey(kind: kind, text: text, person: person),
                createdAt: base.addingTimeInterval(seen), lastSeenAt: base.addingTimeInterval(seen))
}

private func upsert(_ db: AppDatabase, _ f: SalientFlag) throws -> SalientFlag {
    try db.writer.write { try SalientFlagStore(db).upsert(f, in: $0) }
}

private func allFlags(_ db: AppDatabase) throws -> [SalientFlag] {
    try db.reader.read { try SalientFlag.fetchAll($0, sql: "SELECT * FROM salient_flags ORDER BY id") }
}

@Test func dedupeKeyFoldsTextAndPersonAndKeepsKind() {
    let a = SalientFlagStore.dedupeKey(kind: .commitment, text: "Envoyer le  deck à Élodie", person: "Élodie")
    let b = SalientFlagStore.dedupeKey(kind: .commitment, text: "envoyer le deck a elodie", person: "ELODIE")
    #expect(a == b)
    #expect(a.hasPrefix("commitment|") && a.count == "commitment|".count + 16)
    #expect(SalientFlagStore.dedupeKey(kind: .todo, text: "envoyer le deck a elodie", person: "elodie") != a)
    #expect(SalientFlagStore.dedupeKey(kind: .commitment, text: "envoyer le deck a elodie", person: "Marc") != a)
    // The key never carries the text itself.
    #expect(!a.contains("deck"))
}

@Test func upsertMergesOnTheDedupeKeyAndKeepsStatus() throws {
    let db = try AppDatabase.inMemory()
    let first = try upsert(db, flag(ids: [1, 2]))
    try SalientFlagStore(db).setStatus(id: try #require(first.id), .dismissed, closeSnapshotIDs: [], confidence: nil,
                                       at: base.addingTimeInterval(30))
    // The same commitment worded with other case and spacing an hour later.
    let merged = try upsert(db, flag(.commitment, "send  MARC the deck", person: "marc", ids: [2, 3], seen: 3_600))
    #expect(merged.id == first.id)
    let rows = try allFlags(db)
    #expect(rows.count == 1)
    #expect(rows[0].snapshotIDs == [1, 2, 3])
    #expect(rows[0].lastSeenAt == base.addingTimeInterval(3_600))
    #expect(rows[0].createdAt == base)
    #expect(rows[0].status == .dismissed)
}

@Test func upsertNeverMovesLastSeenBackAndFillsAMissingDueDate() throws {
    let db = try AppDatabase.inMemory()
    _ = try upsert(db, flag(seen: 3_600))
    _ = try upsert(db, flag(due: 86_400, seen: 0))
    let row = try #require(try allFlags(db).first)
    #expect(row.lastSeenAt == base.addingTimeInterval(3_600))
    #expect(row.dueAt == base.addingTimeInterval(86_400))
}

@Test func openListsOnlyOpenFlagsOfTheGivenKinds() throws {
    let db = try AppDatabase.inMemory()
    let a = try upsert(db, flag(.commitment, "A", due: 7_200))
    _ = try upsert(db, flag(.todo, "B", due: 3_600))
    _ = try upsert(db, flag(.event, "C"))
    _ = try upsert(db, flag(.todo, "D"))
    try SalientFlagStore(db).setStatus(id: try #require(a.id), .done, closeSnapshotIDs: [9], confidence: 0.9, at: base)
    let open = try SalientFlagStore(db).open(kinds: [.commitment, .todo], limit: 10)
    #expect(open.map(\.text) == ["B", "D"])
    #expect(try SalientFlagStore(db).open(kinds: [.todo], limit: 1).map(\.text) == ["B"])
}

@Test func dueSoonListsOpenFlagsDueBeforeTheHorizon() throws {
    let db = try AppDatabase.inMemory()
    _ = try upsert(db, flag(.event, "later", due: 3 * 86_400))
    _ = try upsert(db, flag(.event, "tomorrow", due: 86_400))
    _ = try upsert(db, flag(.todo, "overdue", due: -3_600))
    _ = try upsert(db, flag(.todo, "undated"))
    let closed = try upsert(db, flag(.todo, "done already", due: 3_600))
    try SalientFlagStore(db).setStatus(id: try #require(closed.id), .done, closeSnapshotIDs: [], confidence: 0.8, at: base)
    let soon = try SalientFlagStore(db).dueSoon(within: 2 * 86_400, now: base, limit: 10)
    #expect(soon.map(\.text) == ["overdue", "tomorrow"])
}

@Test func setStatusRecordsClosureEvidence() throws {
    let db = try AppDatabase.inMemory()
    let row = try upsert(db, flag())
    let at = base.addingTimeInterval(600)
    try SalientFlagStore(db).setStatus(id: try #require(row.id), .done, closeSnapshotIDs: [7, 8], confidence: 0.85, at: at)
    var stored = try #require(try allFlags(db).first)
    #expect(stored.status == .done && stored.closedAt == at && stored.checkedAt == at)
    #expect(stored.closeSnapshotIDs == [7, 8] && stored.confidence == 0.85)

    // Checked but still open: no closing time, confidence unchanged when nil.
    try SalientFlagStore(db).setStatus(id: try #require(row.id), .open, closeSnapshotIDs: [], confidence: nil,
                                       at: at.addingTimeInterval(60))
    stored = try #require(try allFlags(db).first)
    #expect(stored.status == .open && stored.closedAt == nil && stored.checkedAt == at.addingTimeInterval(60))
    #expect(stored.confidence == 0.85 && stored.closeSnapshotIDs == [7, 8])
}
