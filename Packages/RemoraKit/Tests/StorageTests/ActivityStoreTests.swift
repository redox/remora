import Foundation
import GRDB
import Testing
@testable import Storage

@Test func focusExtendsThenSplitsEvents() throws {
    let s = ActivityStore(try .inMemory()); let t0 = Date(timeIntervalSince1970: 1_000)
    try s.recordFocus(app: "Slack", bundleID: nil, windowTitle: "a", domain: nil, at: t0)
    try s.recordFocus(app: "Slack", bundleID: nil, windowTitle: "a", domain: nil, at: t0 + 30)
    try s.recordFocus(app: "Mail", bundleID: nil, windowTitle: "b", domain: nil, at: t0 + 60)
    let e = try s.events(since: t0)
    #expect(e.count == 2 && e[0].endedAt == t0 + 60 && e[1].startedAt == t0 + 60)
}

@Test func deleteAllClearsEvents() throws {
    let s = ActivityStore(try .inMemory()); let t0 = Date(timeIntervalSince1970: 1_000)
    try s.recordFocus(app: "Slack", bundleID: nil, windowTitle: "a", domain: nil, at: t0)
    try s.recordFocus(app: "Mail", bundleID: nil, windowTitle: "b", domain: nil, at: t0 + 60)
    try s.deleteAll()
    #expect(try s.events(since: .distantPast).isEmpty)
}

@Test func combinedDeleteClearsSnapshotsIndexAndActivityKeepsExclusions() throws {
    let db = try AppDatabase.inMemory()
    let t0 = Date(timeIntervalSince1970: 1_000)
    try ActivityStore(db).recordFocus(app: "Slack", bundleID: nil, windowTitle: "a", domain: nil, at: t0)
    try ExclusionStore(db).add("app:Notes")
    try db.writer.write { d in
        try d.execute(sql: "INSERT INTO snapshots (captured_at, app, text, content_hash, source) VALUES (?, 'A', 'hello world', 'h', 'ax')", arguments: [t0])
    }
    func counts() throws -> [Int] {
        try db.reader.read { d in
            [try Int.fetchOne(d, sql: "SELECT count(*) FROM snapshots") ?? -1,
             try Int.fetchOne(d, sql: "SELECT count(*) FROM snapshots_fts WHERE snapshots_fts MATCH 'hello'") ?? -1,
             try Int.fetchOne(d, sql: "SELECT count(*) FROM activity_events") ?? -1]
        }
    }
    #expect(try counts() == [1, 1, 1])
    try DataReset.deleteAllCapturedData(in: db)
    let counts: [Int] = try db.reader.read { d in
        [try Int.fetchOne(d, sql: "SELECT count(*) FROM snapshots") ?? -1,
         try Int.fetchOne(d, sql: "SELECT count(*) FROM snapshots_fts WHERE snapshots_fts MATCH 'hello'") ?? -1,
         try Int.fetchOne(d, sql: "SELECT count(*) FROM activity_events") ?? -1]
    }
    #expect(counts == [0, 0, 0])
    #expect(try ExclusionStore(db).all() == ["app:Notes"])
}

// MARK: - Idle gaps (final review #3)

@Test func gapLongerThan30sOpensNewEventAndLeavesOldAsIs() throws {
    let s = ActivityStore(try .inMemory()); let t0 = Date(timeIntervalSince1970: 1_000)
    try s.recordFocus(app: "Slack", bundleID: nil, windowTitle: "a", domain: nil, at: t0)
    try s.recordFocus(app: "Slack", bundleID: nil, windowTitle: "a", domain: nil, at: t0 + 5)
    // User idle (or screen locked) for 10 minutes, then back on the same window.
    try s.recordFocus(app: "Slack", bundleID: nil, windowTitle: "a", domain: nil, at: t0 + 605)
    try s.recordFocus(app: "Slack", bundleID: nil, windowTitle: "a", domain: nil, at: t0 + 610)
    let e = try s.events(since: .distantPast)
    #expect(e.count == 2)
    #expect(e[0].startedAt == t0 && e[0].endedAt == t0 + 5)
    #expect(e[1].startedAt == t0 + 605 && e[1].endedAt == t0 + 610)
}

@Test func gapBeforeSwitchDoesNotBookIdleTimeOnPreviousWindow() throws {
    let s = ActivityStore(try .inMemory()); let t0 = Date(timeIntervalSince1970: 1_000)
    try s.recordFocus(app: "Slack", bundleID: nil, windowTitle: "a", domain: nil, at: t0)
    try s.recordFocus(app: "Mail", bundleID: nil, windowTitle: "b", domain: nil, at: t0 + 300)
    let e = try s.events(since: .distantPast)
    #expect(e.count == 2 && e[0].endedAt == t0 && e[1].startedAt == t0 + 300)
}

@Test func continuousTicksStillExtend() throws {
    let s = ActivityStore(try .inMemory()); let t0 = Date(timeIntervalSince1970: 1_000)
    for i in 0...24 {  // every 5 s for 2 minutes
        try s.recordFocus(app: "Xcode", bundleID: nil, windowTitle: "p", domain: nil, at: t0 + Double(i * 5))
    }
    let e = try s.events(since: .distantPast)
    #expect(e.count == 1 && e[0].startedAt == t0 && e[0].endedAt == t0 + 120)
    #expect(ActivityStore.idleGap == 30)
}

@Test func outOfOrderTimestampIsClamped() throws {
    let s = ActivityStore(try .inMemory()); let t0 = Date(timeIntervalSince1970: 1_000)
    try s.recordFocus(app: "Slack", bundleID: nil, windowTitle: "a", domain: nil, at: t0 + 10)
    try s.recordFocus(app: "Mail", bundleID: nil, windowTitle: "b", domain: nil, at: t0)  // earlier
    let e = try s.events(since: .distantPast)
    #expect(e.count == 2)
    #expect(e[0].endedAt == t0 + 10)
    #expect(e[1].startedAt == t0 + 10 && e[1].endedAt == t0 + 10)
}

@Test func focusTotalsAreClippedAndGroupedInSQL() throws {
    let db = try AppDatabase.inMemory()
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    try db.writer.write { d in
        for (app, title, from, to) in [("Mail", "Inbox", -600.0, 300.0), ("Mail", "Inbox", 600, 900),
                                       ("Mail", "Draft", 1_000, 1_100), ("Xcode", nil, 3_000, 4_200),
                                       ("Notes", nil, 4_000, 4_500)] as [(String, String?, Double, Double)] {
            var e = ActivityEvent(app: app, windowTitle: title, startedAt: t0 + from, endedAt: t0 + to)
            try e.insert(d)
        }
    }
    let totals = try ActivityStore(db).focusTotals(in: DateInterval(start: t0, duration: 3_600))
    #expect(totals.map(\.app) == ["Mail", "Mail", "Xcode"])
    #expect(totals.map(\.windowTitle) == ["Draft", "Inbox", nil])
    #expect(totals.map(\.seconds) == [100, 600, 600])
}
