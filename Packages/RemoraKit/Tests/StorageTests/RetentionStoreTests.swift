import Foundation
import GRDB
import Testing
@testable import Storage

// Retention vs evidence (plan 4 Review Focus 5): a snapshot past the window is deleted only when
// an hour chronicle covers it and no wiki fact or open flag cites it. Retention never cascades.

private let rtNow = Date(timeIntervalSince1970: 1_795_000_000)
private let day: TimeInterval = 86_400

private func ago(_ days: Double, _ minutes: Double = 0) -> Date {
    rtNow.addingTimeInterval(-days * day + minutes * 60)
}

private func snapshot(_ db: AppDatabase, _ text: String, at: Date, firstAt: Date? = nil) throws -> Int64 {
    try #require(try SnapshotStore(db).insert(Snapshot(capturedAt: at, app: "Notes", text: text,
                                                       contentHash: "h-\(text)", source: .ax,
                                                       firstCapturedAt: firstAt)).id)
}

/// The hour chronicle `[start, start + length)` citing `ids`; summarised (entities done, clean)
/// unless told otherwise.
@discardableResult
private func hour(_ db: AppDatabase, _ start: Date, ids: [Int64] = [], length: TimeInterval = 3_600,
                  entitiesDone: Bool = true, dirty: Bool = false) throws -> Chronicle {
    try db.writer.write { d in
        var c = Chronicle(level: .hour, periodKey: "h\(start.timeIntervalSince1970)", periodStart: start,
                          periodEnd: start.addingTimeInterval(length), summary: "hour",
                          metadata: Chronicle.Metadata(entitiesDone: entitiesDone), snapshotIDs: ids,
                          isDirty: dirty, generatedAt: start)
        try c.insert(d)
        return c
    }
}

private func citeByFact(_ db: AppDatabase, _ ids: [Int64], invalid: Bool) throws {
    try db.writer.write { d in
        if try WikiStore.page(slug: "ada", in: d) == nil {
            _ = try WikiStore.insert(WikiPage(slug: "ada", type: .person, title: "Ada", firstSeen: rtNow,
                                              lastSeen: rtNow, updatedAt: rtNow), in: d)
        }
        let text = "fact \(ids)"
        _ = try WikiStore.insert(WikiFact(slug: "ada", fact: text, normKey: TextFold.key(text), subject: .thirdParty,
                                          basis: .onScreenContent, worth: .core, snapshotIDs: ids, validAt: rtNow,
                                          invalidAt: invalid ? rtNow : nil, recordedAt: rtNow, lastConfirmedAt: rtNow),
                                 in: d)
    }
}

private func citeByFlag(_ db: AppDatabase, _ ids: [Int64], status: FlagStatus) throws {
    try db.writer.write { d in
        let text = "flag \(ids) \(status)"
        var f = SalientFlag(kind: .commitment, text: text, owner: .user, status: status, snapshotIDs: ids,
                            dedupeKey: SalientFlagStore.dedupeKey(kind: .commitment, text: text, person: ""),
                            createdAt: rtNow, lastSeenAt: rtNow)
        try f.insert(d)
    }
}

private struct Fixture {
    var db: AppDatabase
    var s1, s2, s3, s4, s5, s6: Int64
}

/// s1…s5 are 40 days old, s6 is 10 days old. Hours cover all but s5. s2 is cited by an invalid
/// fact, s3 by an open flag, s4 by a done flag.
private func fixture() throws -> Fixture {
    let db = try AppDatabase.inMemory()
    let old = ago(40), covered = ago(40).addingTimeInterval(-600)
    let s1 = try snapshot(db, "s1", at: old)
    let s2 = try snapshot(db, "s2", at: old.addingTimeInterval(60))
    let s3 = try snapshot(db, "s3", at: old.addingTimeInterval(120))
    let s4 = try snapshot(db, "s4", at: old.addingTimeInterval(180))
    let s5 = try snapshot(db, "s5", at: ago(41))
    let s6 = try snapshot(db, "s6", at: ago(10))
    try hour(db, covered, ids: [s1, s2, s3, s4])
    try hour(db, ago(10).addingTimeInterval(-600), ids: [s6])
    try citeByFact(db, [s2], invalid: true)
    try citeByFlag(db, [s3], status: .open)
    try citeByFlag(db, [s4], status: .done)
    return Fixture(db: db, s1: s1, s2: s2, s3: s3, s4: s4, s5: s5, s6: s6)
}

@Test func retentionKeepsCitedAndUncoveredSnapshots() throws {
    let f = try fixture()
    let store = RetentionStore(f.db)
    #expect(try store.deletable(olderThan: ago(30), limit: 500) == [f.s1, f.s4])
    #expect(try store.delete([f.s1, f.s4]) == 2)
    let left = try SnapshotStore(f.db).snapshots(ids: [f.s1, f.s2, f.s3, f.s4, f.s5, f.s6]).compactMap(\.id)
    #expect(Set(left) == [f.s2, f.s3, f.s5, f.s6])
    #expect(try store.deletable(olderThan: ago(30), limit: 500) == [])
}

@Test func loweringTheWindowReachesOnlyCoveredUncitedRows() throws {
    let f = try fixture()
    let store = RetentionStore(f.db)
    #expect(try store.deletable(olderThan: ago(7), limit: 500) == [f.s1, f.s4, f.s6])
    #expect(try store.deletable(olderThan: ago(7), limit: 2) == [f.s1, f.s4])
}

@Test func retentionNeverCascades() throws {
    let f = try fixture()
    let store = RetentionStore(f.db)
    #expect(try store.delete(try store.deletable(olderThan: ago(30), limit: 500)) == 2)
    // The chronicle keeps recording what it summarised, and is not dirtied.
    let hour = try #require(try f.db.reader.read {
        try Chronicle.fetchOne($0, sql: "SELECT * FROM chronicle WHERE level = 'hour' ORDER BY period_start LIMIT 1")
    })
    #expect(hour.snapshotIDs == [f.s1, f.s2, f.s3, f.s4])
    #expect(!hour.isDirty)
    #expect(try SnapshotStore(f.db).search("s1").isEmpty)
}

@Test func deleteRechecksEvidenceInsideItsTransaction() throws {
    let f = try fixture()
    let store = RetentionStore(f.db)
    let ids = try store.deletable(olderThan: ago(30), limit: 500)
    // A fact cites s1 between the read and the delete: s1 must survive.
    try citeByFact(f.db, [f.s1], invalid: false)
    #expect(try store.delete(ids) == 1)
    #expect(try SnapshotStore(f.db).snapshots(ids: [f.s1]).count == 1)
}

@Test func rollingRowNeedsCoverageOfItsWholeLife() throws {
    let db = try AppDatabase.inMemory()
    let firstHour = ago(40)
    // Live from 10 minutes before the end of one hour into the next one.
    let rolled = try snapshot(db, "rolled", at: firstHour.addingTimeInterval(3_600 + 300),
                              firstAt: firstHour.addingTimeInterval(3_000))
    try hour(db, firstHour, ids: [rolled])
    let store = RetentionStore(db)
    #expect(try store.deletable(olderThan: ago(30), limit: 500) == [])
    #expect(try store.awaitingSummary(olderThan: ago(30), isAllowed: { _ in true }) == 1)
    try hour(db, firstHour.addingTimeInterval(3_600), ids: [rolled])
    #expect(try store.deletable(olderThan: ago(30), limit: 500) == [rolled])
    #expect(try store.awaitingSummary(olderThan: ago(30), isAllowed: { _ in true }) == 0)
}

@Test func awaitingSummaryCountsOnlyUncoveredOldRows() throws {
    let f = try fixture()
    // Only s5 is past the window with no hour chronicle (cited rows are covered).
    #expect(try RetentionStore(f.db).awaitingSummary(olderThan: ago(30), isAllowed: { _ in true }) == 1)
    #expect(try RetentionStore(f.db).awaitingSummary(olderThan: ago(50), isAllowed: { _ in true }) == 0)
}

@Test func onlyACleanHourWithEntitiesDoneCovers() throws {
    let db = try AppDatabase.inMemory()
    let start = ago(40)
    // Call B has not run for this hour: its facts and flags may still cite the snapshot.
    let noEntities = try snapshot(db, "no entities yet", at: start.addingTimeInterval(600))
    try hour(db, start, ids: [noEntities], entitiesDone: false)
    // A dirty hour is about to be re-summarised from its snapshots.
    let dirtyStart = start.addingTimeInterval(7_200)
    let inDirty = try snapshot(db, "in a dirty hour", at: dirtyStart.addingTimeInterval(600))
    // A clean, long span starting earlier must not stand in for the dirty row that contains it.
    try hour(db, dirtyStart.addingTimeInterval(-3_600), ids: [], length: 3_600 * 3)
    try hour(db, dirtyStart, ids: [inDirty], dirty: true)
    let store = RetentionStore(db)
    #expect(try store.deletable(olderThan: ago(30), limit: 500) == [])
    #expect(try store.awaitingSummary(olderThan: ago(30), isAllowed: { _ in true }) == 2)

    try db.writer.write { d in try d.execute(sql: "UPDATE chronicle SET is_dirty = 0, metadata = '{\"entities_done\":true}'") }
    #expect(try store.deletable(olderThan: ago(30), limit: 500) == [noEntities, inDirty])
}

@Test func coverageAcrossTheParisFallBackHourAndAMergedSpan() throws {
    // 2026-10-25 in Europe/Paris: 03:00 CEST becomes 02:00 CET, so 02:xx happens twice.
    let iso = ISO8601DateFormatter()
    func utc(_ s: String) -> Date { iso.date(from: s)! }
    let db = try AppDatabase.inMemory()
    let firstTwoThirty = try snapshot(db, "02:30 CEST", at: utc("2026-10-25T00:30:00Z"))
    let secondTwoThirty = try snapshot(db, "02:30 CET", at: utc("2026-10-25T01:30:00Z"))
    let rolled = try snapshot(db, "rolled across the repeat", at: utc("2026-10-25T01:05:00Z"),
                              firstAt: utc("2026-10-25T00:55:00Z"))
    let afterSpan = try snapshot(db, "03:10 CET", at: utc("2026-10-25T02:10:00Z"))
    // One merged sparse span 01:00 CEST → 03:00 CET: three real hours.
    try hour(db, utc("2026-10-24T23:00:00Z"), ids: [firstTwoThirty, secondTwoThirty, rolled], length: 3 * 3_600)
    let store = RetentionStore(db)
    let cutoff = utc("2026-11-30T00:00:00Z")
    #expect(try store.deletable(olderThan: cutoff, limit: 500) == [firstTwoThirty, rolled, secondTwoThirty])
    #expect(try store.awaitingSummary(olderThan: cutoff, isAllowed: { _ in true }) == 1)
    #expect(afterSpan > 0)
}

@Test func unsummarisableCandidatesAreUncoveredAndUncitedAndRecheckedOnDelete() throws {
    let f = try fixture()
    let store = RetentionStore(f.db)
    // s5 is the only uncovered row; it is uncited.
    let page = try store.uncoveredCandidates(olderThan: ago(30), afterID: 0, limit: 10)
    #expect(page.compactMap(\.id) == [f.s5])
    #expect(page.first?.text == "" && page.first?.app == "Notes")
    #expect(try store.uncoveredCandidates(olderThan: ago(30), afterID: f.s5, limit: 10).isEmpty)
    // Rows the caller says are no longer allowed are not "awaiting summary".
    #expect(try store.awaitingSummary(olderThan: ago(30), isAllowed: { _ in false }) == 0)
    // Cited between the read and the delete: kept.
    try citeByFlag(f.db, [f.s5], status: .open)
    #expect(try f.db.writer.write { try RetentionStore.deleteUnsummarisable([f.s5], in: $0) } == 0)
    #expect(try store.awaitingSummary(olderThan: ago(30), isAllowed: { _ in false }) == 1)
}

// MARK: - Tombstones (final review #4)

private func tombstones(_ db: AppDatabase) throws -> [Int64: SnapshotTombstone] {
    try db.reader.read { d in
        try SnapshotTombstones.fetch(try Int64.fetchAll(d, sql: "SELECT id FROM snapshot_sources"), in: d)
    }
}

@Test func retentionLeavesATombstoneWithoutText() throws {
    let db = try AppDatabase.open(at: tempDir().appending(path: "remora.sqlite"))
    let covered = try #require(try SnapshotStore(db).insert(Snapshot(
        capturedAt: ago(40), app: "Safari", bundleID: "com.apple.Safari", windowTitle: "Secret title",
        url: "https://Docs.Example.com/private/page", domain: "docs.example.com", text: "secret body",
        contentHash: "h-safari", source: .ax)).id)
    try hour(db, ago(40, -10), ids: [covered])
    let uncovered = try snapshot(db, "uncovered", at: ago(45))
    #expect(try RetentionStore(db).delete([covered]) == 1)
    #expect(try db.writer.write { try RetentionStore.deleteUnsummarisable([uncovered], in: $0) } == 1)

    let stones = try tombstones(db)
    #expect(stones[covered] == SnapshotTombstone(id: covered, app: "Safari", bundleID: "com.apple.Safari",
                                                 domain: "docs.example.com", urlHost: "docs.example.com"))
    #expect(stones[uncovered]?.app == "Notes")
    let columns = try db.reader.read { try $0.columns(in: "snapshot_sources").map(\.name) }
    #expect(columns == ["id", "app", "bundle_id", "domain", "url_host"])
}

@Test func forgetAndDeleteAllRemoveTombstonesAndCompactionPrunesUncited() throws {
    let db = try AppDatabase.open(at: tempDir().appending(path: "remora.sqlite"))
    let a = try snapshot(db, "a", at: ago(45)), b = try snapshot(db, "b", at: ago(45)), c = try snapshot(db, "c", at: ago(45))
    // The hour cites a and b: their tombstones stay cited; c's is cited by nothing.
    try hour(db, ago(10), ids: [a, b])
    try db.writer.write { _ = try RetentionStore.deleteUnsummarisable([a, b, c], in: $0) }
    #expect(Set(try tombstones(db).keys) == [a, b, c])

    #expect(try db.writer.write { try SnapshotTombstones.pruneUncited(in: $0) } == 1)
    #expect(Set(try tombstones(db).keys) == [a, b])

    // Forgetting a (already deleted by retention) removes its tombstone.
    _ = try SnapshotStore(db).delete(ids: [a], now: rtNow)
    #expect(Set(try tombstones(db).keys) == [b])

    try DataReset.deleteAllCapturedData(in: db, scrub: { _ in })
    #expect(try tombstones(db).isEmpty)
}
