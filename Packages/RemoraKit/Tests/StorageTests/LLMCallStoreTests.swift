import Foundation
import GRDB
import Testing
@testable import Storage

@Test func generatedByMatchesSpecShape() throws {
    let s = LLMCallStore(try .inMemory())
    let c = try s.insert(.fixture(model: "gpt-6.1-terra", backend: "siwc", input: 1200, output: 80,
                                  cost: nil, at: Date(timeIntervalSince1970: 1_700_000_000)))
    let json = String(decoding: try JSONEncoder().encode(try #require(try s.generatedBy(callID: c.id!))),
                      as: UTF8.self)
    #expect(json.contains("\"input_tokens\":1200") && json.contains("\"est_cost_usd\":null")
            && json.contains("\"at\":1700000000"))
    #expect(json.contains("\"model\":\"gpt-6.1-terra\"") && json.contains("\"backend\":\"siwc\"")
            && json.contains("\"output_tokens\":80"))
    #expect(try s.generatedBy(callID: 9999) == nil)
}

private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = .gmt; return c }

@Test func totalsByDayJobAndModel() throws {
    let s = LLMCallStore(try .inMemory())
    let day1 = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14 UTC
    let day2 = day1.addingTimeInterval(86_400)
    _ = try s.insert(.fixture(model: "gpt-6.1-terra", job: "rewrite", input: 100, output: 10, cost: 0.01, at: day1))
    _ = try s.insert(.fixture(model: "gpt-6.1-terra", job: "rewrite", input: 50, output: 5, cost: nil, at: day1))
    _ = try s.insert(.fixture(model: "gpt-6-luna", job: "hour_chronicle", input: 7, output: 3, cost: nil, at: day2))

    let byJob = try s.totals(.jobType, since: .distantPast)
    let rewrite = try #require(byJob.first { $0.key == "rewrite" })
    #expect(rewrite.calls == 2 && rewrite.estCostUSD == 0.01 && rewrite.unpricedCalls == 1)
    #expect(rewrite.inputTokens == 150 && rewrite.outputTokens == 15)
    let chron = try #require(byJob.first { $0.key == "hour_chronicle" })
    #expect(chron.estCostUSD == nil && chron.unpricedCalls == 1)
    #expect(byJob.map(\.key) == ["rewrite", "hour_chronicle"])  // tokens descending

    let byDay = try s.totals(.day(utc), since: .distantPast)
    #expect(byDay.map(\.key) == ["2023-11-14", "2023-11-15"])
    #expect(try s.totals(.model, since: .distantPast).count == 2)
    // until is exclusive of later rows; since filters earlier ones.
    #expect(try s.totals(.jobType, since: day2, until: nil).map(\.key) == ["hour_chronicle"])
    #expect(try s.totals(.jobType, since: .distantPast, until: day1.addingTimeInterval(1)).map(\.key) == ["rewrite"])
}

@Test func failedAndCancelledCallsCountInTotals() throws {
    let s = LLMCallStore(try .inMemory())
    _ = try s.insert(.fixture(status: .completed))
    _ = try s.insert(.fixture(status: .failed))
    _ = try s.insert(.fixture(status: .cancelled))
    _ = try s.insert(.fixture(status: .limit))
    #expect(try s.totals(.jobType, since: .distantPast).first?.calls == 4)
}

@Test func recentIsNewestFirstAndSetArtifactRoundTrips() throws {
    let s = LLMCallStore(try .inMemory())
    let a = try s.insert(.fixture(at: Date(timeIntervalSince1970: 1_000)))
    let b = try s.insert(.fixture(at: Date(timeIntervalSince1970: 2_000)))
    #expect(try s.recent(limit: 5).map(\.id) == [b.id, a.id])
    try s.setArtifact(callID: a.id!, table: "inline_outputs", id: 7)
    let back = try #require(try s.recent(limit: 5).last)
    #expect(back.artifactTable == "inline_outputs" && back.artifactID == 7)
}

@Test func deletingCallNullsInlineOutputLink() throws {
    let db = try AppDatabase.inMemory()
    let call = try LLMCallStore(db).insert(.fixture())
    let out = try InlineOutputStore(db).insert(.fixture(llmCallID: call.id))
    #expect(out.llmCallID == call.id)
    try db.writer.write { _ = try LLMCall.deleteOne($0, key: call.id!) }
    #expect(try InlineOutputStore(db).recent(limit: 1).first?.llmCallID == nil)
}

@Test func callsInRangeAreNewestFirstAndLimited() throws {
    let s = LLMCallStore(try .inMemory())
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    for i in 0..<5 { _ = try s.insert(.fixture(input: i, at: t0.addingTimeInterval(Double(i) * 10))) }
    let all = try s.calls(since: t0.addingTimeInterval(10), limit: 10)
    #expect(all.map(\.inputTokens) == [4, 3, 2, 1])
    #expect(try s.calls(since: t0, limit: 2).map(\.inputTokens) == [4, 3])
    #expect(try s.calls(since: t0, until: t0.addingTimeInterval(30), limit: 10).map(\.inputTokens) == [2, 1, 0])
}

private final class Box: @unchecked Sendable {   // test-only; guarded by the lock
    private let lock = NSLock()
    private var snaps: [[LLMCall]] = []
    func add(_ s: [LLMCall]) { lock.lock(); snaps.append(s); lock.unlock() }
    var all: [[LLMCall]] { lock.lock(); defer { lock.unlock() }; return snaps }
}

@Test func observationDeliversNewCalls() async throws {
    let s = LLMCallStore(try .inMemory())
    let box = Box()
    let obs = s.observeCalls(since: .distantPast, limit: 10, onChange: { box.add($0) }, onError: { _ in })
    defer { obs.cancel() }
    func wait(for count: Int) async throws {
        for _ in 0..<200 where box.all.count < count { try await Task.sleep(for: .milliseconds(25)) }
    }
    try await wait(for: 1)
    #expect(box.all.first?.isEmpty == true)
    _ = try s.insert(.fixture(input: 7))
    try await wait(for: 2)
    #expect(box.all.count >= 2)
    #expect(box.all.last?.map(\.inputTokens) == [7])
}

@Test func unpricedRowsWithTokensAreListedAndCostIsSetOnce() throws {
    let s = LLMCallStore(try .inMemory())
    let a = try s.insert(.fixture(input: 10, output: 5, cost: nil))
    _ = try s.insert(.fixture(input: 0, output: 0, cost: nil))
    _ = try s.insert(.fixture(input: 10, output: 5, cost: 1))
    #expect(try s.unpricedWithTokens(limit: 10).map(\.id) == [a.id])
    try s.setCostIfUnpriced(id: a.id!, usd: 0.5)
    try s.setCostIfUnpriced(id: a.id!, usd: 9)
    #expect(try s.calls(since: .distantPast, limit: 10).first { $0.id == a.id }?.estCostUSD == 0.5)
}
