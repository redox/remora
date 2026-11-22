import Foundation
import GRDB
import Testing
@testable import Storage

private let t0 = Date(timeIntervalSince1970: 2_000_000)

private func ax(_ text: String, at: Date, app: String = "Messages", title: String? = "Ana",
                domain: String? = nil, source: SnapshotSource = .ax) -> Snapshot {
    Snapshot(capturedAt: at, app: app, windowTitle: title, url: domain.map { "https://\($0)/x" },
             domain: domain, text: text, contentHash: "h-\(text.hashValue)", source: source)
}

private func count(_ db: AppDatabase) throws -> Int {
    try db.reader.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM snapshots") ?? -1 }
}

private func ftsHits(_ db: AppDatabase, _ word: String) throws -> Int {
    try db.reader.read {
        try Int.fetchOne($0, sql: "SELECT count(*) FROM snapshots_fts WHERE snapshots_fts MATCH ?",
                         arguments: [word]) ?? -1
    }
}

private func ftsIntegrity(_ db: AppDatabase) throws {
    try db.writer.write {
        try $0.execute(sql: "INSERT INTO snapshots_fts(snapshots_fts, rank) VALUES('integrity-check', 1)")
    }
}

@Test func growingChatUpdatesOneRowInPlace() throws {
    let db = try AppDatabase.inMemory(); let s = SnapshotStore(db)
    let v1 = "hello ana\nare we still on for lunch\nobsoleteword typing indicator"
    let first = try #require(try s.upsertUnlessPaused(ax(v1, at: t0), now: t0))
    let v2 = "hello ana\nare we still on for lunch\nyes at noon\nperfect see you thereword"
    // 3 of the 3 old lines? No: 2 of 3 survive (67 %), below the threshold: new row.
    let lowOverlap = try #require(try s.upsertUnlessPaused(ax(v2, at: t0 + 60), now: t0 + 60))
    #expect(lowOverlap.id != first.id)

    // (d) Pure growth rolls into one row.
    let db2 = try AppDatabase.inMemory(); let s2 = SnapshotStore(db2)
    let a = "hello ana\nare we still on for lunch\nsee you at the usual place"
    let b = a + "\nyes at noon"
    let c = b + "\nperfect newestword"
    let r1 = try #require(try s2.upsertUnlessPaused(ax(a, at: t0), now: t0))
    let r2 = try #require(try s2.upsertUnlessPaused(ax(b, at: t0 + 30), now: t0 + 30))
    let r3 = try #require(try s2.upsertUnlessPaused(ax(c, at: t0 + 60), now: t0 + 60))
    #expect(r1.id == r2.id && r2.id == r3.id)
    #expect(try count(db2) == 1)
    let row = try #require(try s2.snapshots(ids: [r1.id!]).first)
    #expect(row.text == c && row.capturedAt == t0 + 60 && row.contentHash == "h-\(c.hashValue)")
    #expect(row.firstCapturedAt == t0)
    #expect(try ftsHits(db2, "newestword") == 1)
    #expect(try ftsHits(db2, "noon") == 1)
    try ftsIntegrity(db2)
}

@Test func fiftyLineDocumentLosingOneLineStillRollsAndFTSFollows() throws {
    let db = try AppDatabase.inMemory(); let s = SnapshotStore(db)
    var lines = (0..<49).map { "paragraph number \($0) of the design notes" }
    lines.append("obsoleteword sentence that will be deleted")
    let first = try #require(try s.upsertUnlessPaused(ax(lines.joined(separator: "\n"), at: t0), now: t0))
    lines.removeLast()  // 49 of 50 old lines kept: exactly 98 %
    lines.append("newestword sentence that was added")
    let second = try #require(try s.upsertUnlessPaused(ax(lines.joined(separator: "\n"), at: t0 + 30), now: t0 + 30))
    #expect(first.id == second.id)
    #expect(try ftsHits(db, "obsoleteword") == 0)  // FTS kept in sync by the update triggers
    #expect(try ftsHits(db, "newestword") == 1)
    try ftsIntegrity(db)
}

// (a) A viewport sliding over a long conversation never overwrites what scrolled away.
@Test func scrollingViewportKeepsEarliestContentSearchable() throws {
    let db = try AppDatabase.inMemory(); let s = SnapshotStore(db)
    let conversation = (0..<40).map { "message \($0) word\($0)x from the chat" }
    for tick in 0..<30 {
        let viewport = conversation[tick..<(tick + 10)].joined(separator: "\n")
        _ = try s.upsertUnlessPaused(ax(viewport, at: t0 + Double(tick * 5)), now: t0 + Double(tick * 5))
    }
    #expect(try ftsHits(db, "word0x") >= 1)  // first viewport's top line
    #expect(try ftsHits(db, "word1x") >= 1)
    #expect(try ftsHits(db, "word38x") >= 1)  // last viewport
    #expect(try count(db) == 30)
}

// (b) The 10-minute bound is measured from the row's creation, not its last update.
@Test func continuousGrowthStartsNewRowElevenMinutesAfterCreation() throws {
    let db = try AppDatabase.inMemory(); let s = SnapshotStore(db)
    var text = "start of the document"
    var ids: [Int64] = []
    for minute in 0...11 {
        text += "\nline added at minute \(minute)"
        let at = t0 + Double(minute * 60)
        ids.append(try #require(try s.upsertUnlessPaused(ax(text, at: at), now: at)?.id))
    }
    #expect(Set(ids.prefix(11)).count == 1)  // minutes 0...10 roll into the first row
    #expect(ids[11] != ids[0])  // minute 11: new row
    #expect(try count(db) == 2)
}

// (c) Same window title, big shared sidebar, different conversation: new row.
@Test func conversationSwitchWithLargeSharedSidebarGetsNewRow() throws {
    let db = try AppDatabase.inMemory(); let s = SnapshotStore(db)
    let sidebar = (0..<20).map { "contact \($0) last message preview" }.joined(separator: "\n")
    _ = try s.upsertUnlessPaused(ax(sidebar + "\nbudget for q3\nslides due friday\nalice owns pricing", at: t0), now: t0)
    _ = try s.upsertUnlessPaused(ax(sidebar + "\ndinner on saturday\nbring the wine\nsee you at eight", at: t0 + 30), now: t0 + 30)
    #expect(try count(db) == 2)
    #expect(try ftsHits(db, "pricing") == 1)
}

@Test func differentConversationSameTitleGetsNewRow() throws {
    let db = try AppDatabase.inMemory(); let s = SnapshotStore(db)
    _ = try s.upsertUnlessPaused(ax("budget for q3\nslides due friday\nalice owns pricing", at: t0), now: t0)
    _ = try s.upsertUnlessPaused(ax("dinner on saturday\nbring the wine\nsee you at eight", at: t0 + 60), now: t0 + 60)
    #expect(try count(db) == 2)
}

@Test func elevenMinuteGapGetsNewRow() throws {
    let db = try AppDatabase.inMemory(); let s = SnapshotStore(db)
    let a = "line one here\nline two here\nline three here"
    _ = try s.upsertUnlessPaused(ax(a, at: t0), now: t0)
    _ = try s.upsertUnlessPaused(ax(a + "\nline four", at: t0 + 11 * 60), now: t0 + 11 * 60)
    #expect(try count(db) == 2)
    // Exactly 10 minutes still rolls.
    _ = try s.upsertUnlessPaused(ax(a + "\nline four\nline five", at: t0 + 21 * 60), now: t0 + 21 * 60)
    #expect(try count(db) == 2)
}

@Test func differentDomainOrAppOrClipboardNeverRolls() throws {
    let db = try AppDatabase.inMemory(); let s = SnapshotStore(db)
    let a = "line one here\nline two here\nline three here"
    _ = try s.upsertUnlessPaused(ax(a, at: t0, app: "Safari", title: "Docs", domain: "a.com"), now: t0)
    _ = try s.upsertUnlessPaused(ax(a + "\nmore", at: t0 + 10, app: "Safari", title: "Docs", domain: "b.com"), now: t0 + 10)
    #expect(try count(db) == 2)
    _ = try s.upsertUnlessPaused(ax(a, at: t0 + 20, source: .clipboard), now: t0 + 20)
    _ = try s.upsertUnlessPaused(ax(a + "\nmore", at: t0 + 30, source: .clipboard), now: t0 + 30)
    #expect(try count(db) == 4)
}

@Test func pauseBlocksTheUpdateToo() throws {
    let db = try AppDatabase.inMemory(); let s = SnapshotStore(db)
    let a = "line one here\nline two here\nline three here"
    let first = try #require(try s.upsertUnlessPaused(ax(a, at: t0), now: t0))
    try SettingsStore(db).pause(until: .distantFuture)
    #expect(try s.upsertUnlessPaused(ax(a + "\nline four", at: t0 + 10), now: t0 + 10) == nil)
    let row = try #require(try s.snapshots(ids: [first.id!]).first)
    #expect(row.text == a && row.capturedAt == t0)
}

@Test func continuationRule() {
    #expect(SnapshotStore.continues(old: "a\nb\nc\nd\ne", new: "a\nb\nc\nd\ne\nf"))  // pure growth
    #expect(!SnapshotStore.continues(old: "a\nb\nc\nd\ne", new: "a\nb\nc\nd\nx"))  // 80 %: no longer enough
    #expect(SnapshotStore.continues(old: "  a   b \n\n c ", new: "a b\nc\nd"))  // normalised, blanks ignored
    #expect(!SnapshotStore.continues(old: "\n  \n", new: "a"))  // nothing to continue
    #expect(SnapshotStore.rollingWindow == 600 && SnapshotStore.continuationThreshold == 0.98)
}

@Test func rollingCandidateLookupUsesIndex() throws {
    let db = try AppDatabase.inMemory()
    let detail: [String] = try db.reader.read { d in
        try Row.fetchAll(d, sql: "EXPLAIN QUERY PLAN " + SnapshotStore.rollingCandidateSQL,
                         arguments: ["A", "T", t0, "x.com"]).map { $0["detail"] as String }
    }
    #expect(!detail.contains { $0.hasPrefix("SCAN") || $0.contains("TEMP B-TREE") }, "\(detail)")
}
