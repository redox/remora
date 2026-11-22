import Foundation
import Capture
import GRDB
import LLM
import LLMTestSupport
import Storage
import Testing
@testable import Memory

private let open = CapturePolicy(userRules: [])

@Test func excludedSnapshotsNeverReachPrompt() async throws {
    let env = try pipelineEnv()
    try seedHour(env.db)
    // Exclusions added after capture apply to old snapshots and to their focus time.
    try ExclusionStore(env.db).add("app:Slack")
    try ExclusionStore(env.db).add("kayak.fr")

    let evidence = try HourEvidence.build(db: env.db, span: hourSpan, policy: SnapshotPolicy.current(env.db))
    #expect(!evidence.items.contains { $0.app == "Slack" })
    #expect(!evidence.items.contains { $0.domain == "www.kayak.fr" })
    #expect(!evidence.activity.contains { $0.app == "Slack" || $0.domain == "www.kayak.fr" })
    #expect(evidence.items.contains { $0.app == "Mail" })

    _ = try await env.pipeline.run(try hourJob(env.db), context: hourContext())
    let sent = allInput(env.fake.requests)
    #expect(env.fake.requests.count == 2)
    #expect(!sent.contains("Slack"))
    #expect(!sent.contains("je t'envoie le deck"))
    #expect(!sent.contains("Reminder: all-hands"))
    #expect(!sent.contains("kayak") && !sent.contains("Paris → Oslo"))
    #expect(sent.contains("Oslo offsite budget is 12k€"))
}

@Test func builtInSkipListAppsNeverReachPrompt() async throws {
    let env = try pipelineEnv()
    try seedHour(env.db)
    let evidence = try HourEvidence.build(db: env.db, span: hourSpan, policy: open)
    #expect(!evidence.items.contains { $0.app == "1Password" })
    #expect(!evidence.activity.contains { $0.app == "1Password" })
    _ = try await env.pipeline.run(try hourJob(env.db), context: hourContext())
    let sent = allInput(env.fake.requests)
    #expect(!sent.contains("hunter2") && !sent.contains("1Password"))
}

@Test func unreadableExclusionsDenyEverything() throws {
    let db = try AppDatabase.inMemory()
    try seedHour(db)
    try db.writer.write { try $0.execute(sql: "DROP TABLE exclusions") }
    let evidence = try HourEvidence.build(db: db, span: hourSpan, policy: SnapshotPolicy.current(db))
    #expect(evidence.items.isEmpty && evidence.activity.isEmpty)
}

@Test func evidenceRespectsBudgetAndDedupes() throws {
    let db = try AppDatabase.inMemory()
    let store = SnapshotStore(db)
    for i in 0..<30 {
        let text = "item \(i) " + String(repeating: "x", count: 5_000)
        _ = try store.insert(Snapshot(capturedAt: hourStart.addingTimeInterval(Double(i) * 100), app: "Notes",
                                      bundleID: "com.apple.Notes", windowTitle: "n\(i)", text: text,
                                      contentHash: i == 7 ? "hash-3" : "hash-\(i)", source: .ax))
    }
    let e = try HourEvidence.build(db: db, span: hourSpan, policy: open)
    #expect(e.items.count == 29)
    #expect(e.items.reduce(0) { $0 + $1.text.count } <= 36_000)
    #expect(e.items.allSatisfy { $0.text.count >= 400 && $0.text.count <= 3_000 })
    #expect(e.items.map(\.index) == Array(1...29))
    #expect(e.items.map(\.at) == e.items.map(\.at).sorted())
    #expect(!e.items.contains { $0.text.hasPrefix("item 7 ") })
}

@Test func shortItemsLeaveTheirShareToLongOnes() throws {
    let db = try AppDatabase.inMemory()
    let store = SnapshotStore(db)
    for i in 0..<20 {
        let text = i < 10 ? "short \(i)" : String(repeating: "y", count: 5_000)
        _ = try store.insert(Snapshot(capturedAt: hourStart.addingTimeInterval(Double(i) * 60), app: "Notes",
                                      text: text, contentHash: "h\(i)", source: .ax))
    }
    let e = try HourEvidence.build(db: db, span: hourSpan, policy: open)
    let total = e.items.reduce(0) { $0 + $1.text.count }
    #expect(e.items.count == 20 && total <= 36_000)
    #expect(e.items.filter { $0.text.hasPrefix("short") }.count == 10)
    // Ten long items share what the short ones left, capped per item.
    #expect(e.items.filter { !$0.text.hasPrefix("short") }.allSatisfy { $0.text.count == 3_000 })
}

@Test func tooManyItemsAreSampledAcrossTheHour() throws {
    let db = try AppDatabase.inMemory()
    let store = SnapshotStore(db)
    for i in 0..<120 {
        _ = try store.insert(Snapshot(capturedAt: hourStart.addingTimeInterval(Double(i) * 29), app: "Notes",
                                      text: "n\(i) " + String(repeating: "z", count: 1_000),
                                      contentHash: "h\(i)", source: .ax))
    }
    let e = try HourEvidence.build(db: db, span: hourSpan, policy: open)
    #expect(e.items.count == 90)
    #expect(e.items.reduce(0) { $0 + $1.text.count } <= 36_000)
    #expect(e.items.first?.text.hasPrefix("n0 ") == true && e.items.last?.text.hasPrefix("n119 ") == true)
}

@Test func evidenceSelectsSnapshotsOverlappingTheSpan() throws {
    let db = try AppDatabase.inMemory()
    let store = SnapshotStore(db)
    // Rolled row: created 13:55, last updated 14:03 → overlaps 14:00.
    _ = try store.insert(Snapshot(capturedAt: date(2026, 11, 20, 14, 3), app: "Notes", text: "rolled",
                                  contentHash: "a", source: .ax, firstCapturedAt: date(2026, 11, 20, 13, 55)))
    _ = try store.insert(Snapshot(capturedAt: date(2026, 11, 20, 13, 50), app: "Notes", text: "before",
                                  contentHash: "b", source: .ax, firstCapturedAt: date(2026, 11, 20, 13, 40)))
    _ = try store.insert(Snapshot(capturedAt: hourEnd, app: "Notes", text: "next hour", contentHash: "c", source: .ax))
    _ = try store.insert(Snapshot(capturedAt: date(2026, 11, 20, 14, 30), app: "Notes", text: "inside",
                                  contentHash: "d", source: .ax))
    let e = try HourEvidence.build(db: db, span: hourSpan, policy: open)
    #expect(e.items.map(\.text) == ["rolled", "inside"])
}

@Test func activityIsClippedGroupedAndSorted() throws {
    let db = try AppDatabase.inMemory()
    try insertActivity(db, app: "Xcode", from: date(2026, 11, 20, 13, 50), seconds: 1_200)  // 10 min inside
    try insertActivity(db, app: "Safari", bundleID: "com.apple.Safari", domain: "github.com",
                       from: date(2026, 11, 20, 14, 20), seconds: 300)
    try insertActivity(db, app: "Safari", bundleID: "com.apple.Safari", domain: "github.com",
                       from: date(2026, 11, 20, 14, 40), seconds: 600)
    try insertActivity(db, app: "Safari", bundleID: "com.apple.Safari", from: date(2026, 11, 20, 14, 55), seconds: 60)
    try insertActivity(db, app: "Mail", from: date(2026, 11, 20, 15, 1), seconds: 600)  // outside
    let e = try HourEvidence.build(db: db, span: hourSpan, policy: open)
    #expect(e.activity == [AppTime(app: "Safari", domain: "github.com", seconds: 900),
                           AppTime(app: "Xcode", domain: nil, seconds: 600),
                           AppTime(app: "Safari", domain: nil, seconds: 60)])
    #expect(e.focusSeconds == 1_560)
}

@Test func snapshotIDsForIndicesDropUnknown() throws {
    let db = try AppDatabase.inMemory()
    let rows = try seedHour(db)
    let e = try HourEvidence.build(db: db, span: hourSpan, policy: open)
    let first = try #require(e.items.first), second = e.items[1]
    #expect(first.snapshotID == rows[0].id)
    #expect(e.snapshotIDs(for: [2, 1, 99, 0, 2]) == [second.snapshotID, first.snapshotID])
}

@Test func snapshotPolicyChecksTheDomainWhenTheStoredURLIsUnusable() {
    let policy = CapturePolicy(userRules: [ExclusionRule(pattern: "github.com")!])
    func snap(_ url: String?, _ domain: String?) -> Snapshot {
        Snapshot(capturedAt: hourStart, app: "Safari", bundleID: "com.apple.Safari", url: url, domain: domain,
                 text: "x", contentHash: "h", source: .ax)
    }
    // Redacted URL that does not parse to a host: the stored domain still decides.
    #expect(!SnapshotPolicy.allows(snap("[redacted] /pull/42", "github.com"), policy: policy))
    #expect(SnapshotPolicy.allows(snap("[redacted] /x", "example.com"), policy: open))
    #expect(!SnapshotPolicy.allows(snap("https://github.com/acme", "github.com"), policy: policy))
    // A URL whose host disagrees with the domain: both are checked (fail closed).
    #expect(!SnapshotPolicy.allows(snap("https://example.com/x", "github.com"), policy: policy))
    // A browser snapshot without any URL or domain cannot be checked: denied.
    #expect(!SnapshotPolicy.allows(snap(nil, nil), policy: open))
    // `url:` rules still see the full stored URL.
    let urlRule = CapturePolicy(userRules: [ExclusionRule(pattern: "url:/pull/42")!])
    #expect(!SnapshotPolicy.allows(snap("https://github.com/acme/app/pull/42", "github.com"), policy: urlRule))
    #expect(!SnapshotPolicy.allows(snap("https://github.com/x", "github.com"), policy: .denyAll))
}
