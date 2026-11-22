import Foundation
import GRDB
import Testing
@testable import Storage

// "Forget this" (user-initiated `SnapshotStore.delete(ids:)`) and its provenance cascade.

private let utc: Calendar = {
    var c = Calendar(identifier: .iso8601)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0) -> Date {
    utc.date(from: DateComponents(year: y, month: mo, day: d, hour: h))!
}

private let pvNow = at(2026, 11, 20, 12)

/// Snapshots 1…n (ids are the autoincrement order of a fresh database).
@discardableResult
private func snapshots(_ db: AppDatabase, _ n: Int, text: (Int) -> String = { "note \($0)" }) throws -> [Int64] {
    try (1...n).map { i in
        try #require(try SnapshotStore(db).insert(.fixture(text: text(i), capturedAt: at(2026, 11, 18, 10))).id)
    }
}

@discardableResult
private func chronicle(_ db: AppDatabase, _ level: ChronicleLevel, _ key: String, _ start: Date, _ end: Date,
                       ids: [Int64], dirty: Bool = false) throws -> Chronicle {
    try db.writer.write { d in
        var c = Chronicle(level: level, periodKey: key, periodStart: start, periodEnd: end, summary: "\(level) summary",
                          snapshotIDs: ids, isDirty: dirty, generatedAt: start)
        try c.insert(d)
        return c
    }
}

/// hour 2026-11-18T10, its day, ISO week 47, month 2026-11 and year 2026 (rollups store `[]`).
private func tree(_ db: AppDatabase, hourIDs: [Int64], dayIDs: [Int64]) throws {
    try chronicle(db, .hour, "2026-11-18T10", at(2026, 11, 18, 10), at(2026, 11, 18, 11), ids: hourIDs)
    try chronicle(db, .day, "2026-11-18", at(2026, 11, 18), at(2026, 11, 19), ids: dayIDs)
    try chronicle(db, .week, "2026-W47", at(2026, 11, 16), at(2026, 11, 23), ids: [])
    try chronicle(db, .month, "2026-11", at(2026, 11, 1), at(2026, 12, 1), ids: [])
    try chronicle(db, .year, "2026", at(2026, 1, 1), at(2027, 1, 1), ids: [])
}

private func row(_ db: AppDatabase, _ level: ChronicleLevel, _ key: String) throws -> Chronicle? {
    try db.reader.read { try ChronicleStore(db).chronicle(level, key: key, in: $0) }
}

private func page(_ db: AppDatabase, _ slug: String, ids: [Int64] = [], dirty: Bool = false) throws -> WikiPage {
    try db.writer.write { d in
        try WikiStore.insert(WikiPage(slug: slug, type: .person, title: slug.capitalized, firstSeen: pvNow,
                                      lastSeen: pvNow, isDirty: dirty, snapshotIDs: ids, updatedAt: pvNow), in: d)
    }
}

private func fact(_ db: AppDatabase, _ slug: String, _ text: String, ids: [Int64], supersededBy: Int64? = nil,
                  invalid: Bool = false) throws -> WikiFact {
    try db.writer.write { d in
        try WikiStore.insert(WikiFact(slug: slug, fact: text, normKey: TextFold.key(text), subject: .thirdParty,
                                      basis: .onScreenContent, worth: .core, snapshotIDs: ids, validAt: pvNow,
                                      invalidAt: invalid ? pvNow : nil, supersededBy: supersededBy,
                                      recordedAt: pvNow, lastConfirmedAt: pvNow), in: d)
    }
}

private func flag(_ db: AppDatabase, _ text: String, ids: [Int64], close: [Int64] = [],
                  status: FlagStatus = .open) throws -> SalientFlag {
    try db.writer.write { d in
        var f = SalientFlag(kind: .todo, text: text, owner: .user, status: status, snapshotIDs: ids,
                            closeSnapshotIDs: close,
                            dedupeKey: SalientFlagStore.dedupeKey(kind: .todo, text: text, person: ""),
                            createdAt: pvNow, lastSeenAt: pvNow)
        try f.insert(d)
        return f
    }
}

private func workingMemory(_ db: AppDatabase, _ text: String, ids: [Int64]) throws -> WorkingMemoryItem {
    try db.writer.write { d in
        var w = WorkingMemoryItem(text: text, kind: "task", normKey: TextFold.key(text), relevance: 0.8,
                                  snapshotIDs: ids, addedAt: pvNow, lastSeenAt: pvNow)
        try w.insert(d)
        return w
    }
}

private func vector(_ db: AppDatabase, _ owner: EmbeddingOwner, _ id: Int64) throws {
    try db.writer.write { d in
        try EmbeddingStore.upsert(owner: owner, ownerID: id, identity: EmbedderIdentity(modelID: "m", revision: 1, dimension: 2),
                                  vector: [1, 0], contentHash: "h", at: pvNow, in: d)
    }
}

private func count(_ db: AppDatabase, _ sql: String) throws -> Int {
    try db.reader.read { try Int.fetchOne($0, sql: sql) ?? 0 }
}

@Test func cascadeDeletesSoleSourceRowsAndDirtiesOthers() throws {
    let db = try AppDatabase.inMemory()
    let ids = try snapshots(db, 2)
    let (s1, s2) = (ids[0], ids[1])
    _ = try page(db, "marc", ids: [s1, s2])
    let a = try fact(db, "marc", "Marc leads the Oslo offsite", ids: [s1])
    let b = try fact(db, "marc", "Marc lives in Paris", ids: [s1, s2])
    // An older fact superseded by A: the foreign key goes back to NULL when A is deleted.
    let older = try fact(db, "marc", "Marc leads nothing", ids: [s2], supersededBy: a.id, invalid: true)
    try vector(db, .wikiFact, try #require(a.id))
    try vector(db, .wikiFact, try #require(b.id))
    try chronicle(db, .hour, "2026-11-18T10", at(2026, 11, 18, 10), at(2026, 11, 18, 11), ids: [s1, s2])
    let soleFlag = try flag(db, "Send the deck", ids: [s1])
    let sharedFlag = try flag(db, "Book the venue", ids: [s1, s2], close: [s1])
    let soleWM = try workingMemory(db, "Oslo deck", ids: [s1])
    let sharedWM = try workingMemory(db, "Venue booking", ids: [s1, s2])

    let report = try SnapshotStore(db).delete(ids: [s1], now: pvNow)

    #expect(try SnapshotStore(db).snapshots(ids: [s1, s2]).compactMap(\.id) == [s2])
    #expect(try SnapshotStore(db).search("note").map(\.id) == [s2])
    // Fact A had only s1: gone, with its vector; its page is dirty. Fact B keeps s2.
    #expect(try db.reader.read { try WikiStore.fact(id: a.id!, in: $0) } == nil)
    let keptB = try #require(try db.reader.read { try WikiStore.fact(id: b.id!, in: $0) })
    #expect(keptB.snapshotIDs == [s2])
    #expect(try db.reader.read { try WikiStore.fact(id: older.id!, in: $0) }?.supersededBy == nil)
    #expect(try count(db, "SELECT COUNT(*) FROM embeddings WHERE owner_table = 'wiki_facts'") == 1)
    let marc = try #require(try WikiStore(db).page(slug: "marc"))
    #expect(marc.isDirty && marc.snapshotIDs == [s2])
    // The hour keeps s2 and is dirty.
    let hour = try #require(try row(db, .hour, "2026-11-18T10"))
    #expect(hour.snapshotIDs == [s2] && hour.isDirty)
    // Flags and working memory: sole-source rows go, others only lose the id.
    let flags = try db.reader.read { try SalientFlag.fetchAll($0, sql: "SELECT * FROM salient_flags ORDER BY id") }
    #expect(flags.map(\.id) == [sharedFlag.id])
    #expect(flags.first?.snapshotIDs == [s2] && flags.first?.closeSnapshotIDs == [])
    #expect(soleFlag.id != nil)
    let wm = try db.reader.read { try WorkingMemoryItem.fetchAll($0, sql: "SELECT * FROM working_memory ORDER BY id") }
    #expect(wm.map(\.id) == [sharedWM.id] && wm.first?.snapshotIDs == [s2])
    #expect(soleWM.id != nil)

    #expect(report.deleted["snapshots"] == 1)
    #expect(report.deleted["wiki_facts"] == 1)
    #expect(report.deleted["salient_flags"] == 1)
    #expect(report.deleted["working_memory"] == 1)
    #expect(report.deleted["embeddings"] == 1)
    #expect(report.dirtied["wiki_pages"] == 1)
    #expect(report.dirtied["wiki_facts"] == 1)
    #expect((report.dirtied["chronicle"] ?? 0) >= 1)
}

@Test func emptyProvenanceArraysAreNeverAllDeleted() throws {
    let db = try AppDatabase.inMemory()
    let ids = try snapshots(db, 2)
    // Week, month and year rows store `[]` by design (provenance rides `child_ids`).
    try tree(db, hourIDs: [ids[1]], dayIDs: [ids[1]])
    let empty = try page(db, "lea", ids: [])
    let emptyFlag = try flag(db, "Call Léa", ids: [])

    try SnapshotStore(db).delete(ids: [ids[0]], now: pvNow)

    for (level, key) in [(ChronicleLevel.hour, "2026-11-18T10"), (.day, "2026-11-18"), (.week, "2026-W47"),
                         (.month, "2026-11"), (.year, "2026")] {
        let c = try #require(try row(db, level, key), "\(level) must survive")
        #expect(!c.isDirty, "\(level) does not cite the forgotten snapshot")
    }
    #expect(try WikiStore(db).page(slug: "lea") == empty)
    #expect(try count(db, "SELECT COUNT(*) FROM salient_flags WHERE id = \(emptyFlag.id!)") == 1)
}

@Test func forgottenSnapshotDirtiesEveryAncestorWithoutReroll() throws {
    let db = try AppDatabase.inMemory()
    let ids = try snapshots(db, 2)
    // The day row carries no snapshot ids at all, so only the transitive touch can reach it.
    try tree(db, hourIDs: ids, dayIDs: [])

    try SnapshotStore(db).delete(ids: [ids[0]], now: pvNow)

    for (level, key) in [(ChronicleLevel.hour, "2026-11-18T10"), (.day, "2026-11-18"), (.week, "2026-W47"),
                         (.month, "2026-11"), (.year, "2026")] {
        #expect(try row(db, level, key)?.isDirty == true, "\(level) must be dirty")
    }
}

@Test func deletedHourDirtiesAncestorsAndRequeuesAFinishedRollupWithoutRow() throws {
    let db = try AppDatabase.inMemory()
    let ids = try snapshots(db, 1)
    try chronicle(db, .hour, "2026-11-18T10", at(2026, 11, 18, 10), at(2026, 11, 18, 11), ids: ids)
    try chronicle(db, .week, "2026-W47", at(2026, 11, 16), at(2026, 11, 23), ids: [])
    try chronicle(db, .month, "2026-11", at(2026, 11, 1), at(2026, 12, 1), ids: [])
    try chronicle(db, .year, "2026", at(2026, 1, 1), at(2027, 1, 1), ids: [])
    // No day row, and its rollup already finished (skipped): it must run again.
    let jobs = JobStore(db)
    _ = try jobs.enqueue([JobSpec(kind: .dayRollup, periodKey: "2026-11-18", periodStart: at(2026, 11, 18),
                                  periodEnd: at(2026, 11, 19), notBefore: at(2026, 11, 19))], now: at(2026, 11, 19))
    let job = try #require(try jobs.job(kind: .dayRollup, periodKey: "2026-11-18"))
    try jobs.complete(id: try #require(job.id), status: .skipped, reason: "no_children", now: at(2026, 11, 19))

    let report = try SnapshotStore(db).delete(ids: ids, now: pvNow)

    #expect(try row(db, .hour, "2026-11-18T10") == nil)
    #expect(report.deleted["chronicle"] == 1)
    #expect(try jobs.status(kind: .dayRollup, periodKey: "2026-11-18") == .pending)
    for (level, key) in [(ChronicleLevel.week, "2026-W47"), (.month, "2026-11"), (.year, "2026")] {
        #expect(try row(db, level, key)?.isDirty == true, "\(level) must be dirty")
    }
}

@Test func pageWithSurvivingFactsIsKept() throws {
    let db = try AppDatabase.inMemory()
    let ids = try snapshots(db, 3)
    _ = try page(db, "oslo", ids: [ids[0]])
    _ = try fact(db, "oslo", "The Oslo offsite budget is 12k€", ids: [ids[1], ids[2]])
    _ = try page(db, "ghost", ids: [ids[0]])
    try vector(db, .wikiPage, try #require(try WikiStore(db).page(slug: "ghost")?.id))

    let report = try SnapshotStore(db).delete(ids: [ids[0]], now: pvNow)

    // Its own mention evidence is gone, but its facts still stand on other snapshots.
    let oslo = try #require(try WikiStore(db).page(slug: "oslo"))
    #expect(oslo.isDirty && oslo.snapshotIDs == [ids[1], ids[2]])
    #expect(try WikiStore(db).page(slug: "ghost") == nil)
    #expect(try count(db, "SELECT COUNT(*) FROM embeddings") == 0)
    #expect(report.deleted["wiki_pages"] == 1)
}

@Test func cascadeWithNoIdsChangesNothing() throws {
    let db = try AppDatabase.inMemory()
    let ids = try snapshots(db, 1)
    try tree(db, hourIDs: ids, dayIDs: ids)
    let report = try db.writer.write { try Provenance.cascade(deletedSnapshotIDs: [], now: pvNow, in: $0) }
    #expect(report == ProvenanceReport())
    #expect(try row(db, .hour, "2026-11-18T10")?.isDirty == false)
}

@Test func forgetBlanksPagesBelowTheRewriteThreshold() throws {
    let db = try AppDatabase.inMemory()
    let ids = try snapshots(db, 2)
    let call = try LLMCallStore(db).insert(.fixture(job: "wiki_writeup"))
    func writtenPage(_ slug: String, mentions: Int) throws {
        try db.writer.write { d in
            _ = try WikiStore.insert(WikiPage(slug: slug, type: .person, title: slug.capitalized,
                                              summary: "\(slug) summary from note 1", body: "\(slug) body quoting note 1",
                                              mentionCount: mentions, firstSeen: pvNow, lastSeen: pvNow,
                                              snapshotIDs: ids, updatedAt: at(2026, 11, 1), llmCallID: call.id), in: d)
        }
        try vector(db, .wikiPage, try #require(try WikiStore(db).page(slug: slug)?.id))
    }
    try writtenPage("once", mentions: 1)
    try writtenPage("often", mentions: WikiStore.minRewriteMentions)

    let report = try SnapshotStore(db).delete(ids: [ids[0]], now: pvNow)

    // Never rewritten below the threshold: its write-up goes now, with its vector.
    let once = try #require(try WikiStore(db).page(slug: "once"))
    #expect(once.summary.isEmpty && once.body.isEmpty && once.isDirty && once.updatedAt == pvNow)
    #expect(once.snapshotIDs == [ids[1]])
    #expect(try count(db, "SELECT COUNT(*) FROM embeddings WHERE owner_id = \(once.id!)") == 0)
    // At the threshold the rewrite job will redo it from what is left: kept until then, dirty.
    let often = try #require(try WikiStore(db).page(slug: "often"))
    #expect(!often.summary.isEmpty && often.isDirty)
    #expect(report.dirtied["wiki_pages_blanked"] == 1)
    #expect(WikiStore.minRewriteMentions == 2)
}

@Test func deletedRollupRequeuesItsOwnJob() throws {
    let db = try AppDatabase.inMemory()
    let ids = try snapshots(db, 1)
    // An activity-only hour survives (it cites nothing); the day cited only the forgotten snapshot.
    try chronicle(db, .hour, "2026-11-18T10", at(2026, 11, 18, 10), at(2026, 11, 18, 11), ids: [])
    try chronicle(db, .day, "2026-11-18", at(2026, 11, 18), at(2026, 11, 19), ids: ids)
    let jobs = JobStore(db)
    _ = try jobs.enqueue([JobSpec(kind: .dayRollup, periodKey: "2026-11-18", periodStart: at(2026, 11, 18),
                                  periodEnd: at(2026, 11, 19), notBefore: at(2026, 11, 19))], now: at(2026, 11, 19))
    try jobs.complete(id: try #require(try jobs.job(kind: .dayRollup, periodKey: "2026-11-18")?.id), status: .done,
                      now: at(2026, 11, 19))

    try SnapshotStore(db).delete(ids: ids, now: pvNow)

    #expect(try row(db, .day, "2026-11-18") == nil)
    #expect(try jobs.status(kind: .dayRollup, periodKey: "2026-11-18") == .pending)
    #expect(try row(db, .hour, "2026-11-18T10") != nil)
}

@Test func ancestorTouchAcrossTheParisFallBackDay() throws {
    // 2026-10-25 in Europe/Paris has 25 hours: 02:00–03:00 happens twice. The day runs from
    // 2026-10-24T22:00Z to 2026-10-25T23:00Z; the repeated 02:00 CET hour is 01:00Z–02:00Z, inside a
    // merged sparse span 01:00 CEST → 03:00 CET (23:00Z–02:00Z).
    let iso = ISO8601DateFormatter()
    func utc(_ s: String) -> Date { iso.date(from: s)! }
    let db = try AppDatabase.inMemory()
    let ids = try snapshots(db, 2)
    try chronicle(db, .hour, "2026-10-25T01+0200", utc("2026-10-24T23:00:00Z"), utc("2026-10-25T02:00:00Z"), ids: ids)
    try chronicle(db, .day, "2026-10-25", utc("2026-10-24T22:00:00Z"), utc("2026-10-25T23:00:00Z"), ids: [])
    try chronicle(db, .week, "2026-W43", utc("2026-10-18T22:00:00Z"), utc("2026-10-25T23:00:00Z"), ids: [])
    try chronicle(db, .month, "2026-10", utc("2026-09-30T22:00:00Z"), utc("2026-10-31T23:00:00Z"), ids: [])
    try chronicle(db, .year, "2026", utc("2025-12-31T23:00:00Z"), utc("2026-12-31T23:00:00Z"), ids: [])
    // The next day and week must not be touched.
    try chronicle(db, .day, "2026-10-26", utc("2026-10-25T23:00:00Z"), utc("2026-10-26T23:00:00Z"), ids: [])
    try chronicle(db, .week, "2026-W44", utc("2026-10-25T23:00:00Z"), utc("2026-11-01T23:00:00Z"), ids: [])

    try SnapshotStore(db).delete(ids: [ids[0]], now: pvNow)

    for (level, key) in [(ChronicleLevel.hour, "2026-10-25T01+0200"), (.day, "2026-10-25"), (.week, "2026-W43"),
                         (.month, "2026-10"), (.year, "2026")] {
        #expect(try row(db, level, key)?.isDirty == true, "\(level) must be dirty")
    }
    #expect(try row(db, .day, "2026-10-26")?.isDirty == false)
    #expect(try row(db, .week, "2026-W44")?.isDirty == false)
}
