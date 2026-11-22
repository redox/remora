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
