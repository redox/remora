import Foundation
import Redaction
import Storage
import Testing
@testable import Retrieval

private let now = Date(timeIntervalSince1970: 1_700_000_000)

private func request(field: String = "", title: String? = "Draft", live: String? = nil, app: String = "Mail",
                     surface: String = "mail", memory: Bool = true) -> ContextRequest {
    ContextRequest(fieldText: field, windowTitle: title, liveWindowText: live, app: app, bundleID: nil,
                   surface: surface, memoryAllowed: memory, now: now)
}

private func snap(_ db: AppDatabase, _ text: String, app: String = "Slack", title: String? = "General",
                  ago: TimeInterval = 60) throws {
    _ = try SnapshotStore(db).insert(Snapshot(capturedAt: now.addingTimeInterval(-ago), app: app, windowTitle: title,
                                              text: text, contentHash: UUID().uuidString, source: .ax))
}

@Test func queryTermsAreFoldedDedupedAndFiltered() {
    let t = QueryTerms.extract(from: ["Bonjour Marc, voici the Budget 2024 avec Budget", "Pour toi: Roadmap"])
    #expect(t == ["bonjour", "marc", "voici", "budget", "roadmap"])
    #expect(QueryTerms.extract(from: ["alpha bravo charlie delta echo foxtrot golf hotel india juliet"], max: 3) == ["alpha", "bravo", "charlie"])
    #expect(QueryTerms.extract(from: ["12345 a bc"]).isEmpty)
}

@Test func excerptCentersOnAccentInsensitiveMatch() {
    let text = String(repeating: "x", count: 600) + " Réunion budget " + String(repeating: "y", count: 600)
    let e = Excerpt.around(terms: ["reunion"], in: text, radius: 50)
    #expect(e.contains("Réunion") && e.hasPrefix("…") && e.hasSuffix("…") && e.count <= 105)
    let none = Excerpt.around(terms: ["zzz"], in: text, radius: 50)
    #expect(none.hasSuffix("…") && !none.hasPrefix("…") && none.count <= 101)
    #expect(Excerpt.around(terms: ["a"], in: "short", radius: 50) == "short")
}

@Test func contextRedactsLiveWindowAndRespectsBudget() async throws {
    let a = ContextAssembler(db: try AppDatabase.inMemory())
    let live = "Pay 4111 1111 1111 1111 now. " + String(repeating: "filler text ", count: 5_000)
    let c = try await a.context(for: request(live: live))
    let w = try #require(c.windowText)
    #expect(w.count <= 12_000)
    let small = try await a.context(for: request(live: "Pay 4111 1111 1111 1111 now"))
    #expect(small.windowText?.contains("[redacted]") == true && small.windowText?.contains("4111") == false)
}

@Test func longWindowKeepsPortionEndingAtField() async throws {
    let a = ContextAssembler(db: try AppDatabase.inMemory())
    let live = "START " + String(repeating: "a ", count: 10_000) + "MY FIELD TEXT" + String(repeating: " z", count: 10_000)
    let w = try #require(try await a.context(for: request(field: "MY FIELD TEXT", live: live)).windowText)
    #expect(w.hasSuffix("MY FIELD TEXT") && !w.contains("START") && w.count <= 12_000)
    let tail = try #require(try await a.context(for: request(field: "", live: live)).windowText)
    #expect(tail.hasSuffix(" z") && w != tail)
}

@Test func contextFindsRelatedSnapshotsExcludingCurrentWindow() async throws {
    let db = try AppDatabase.inMemory()
    try snap(db, "The quarterly roadmap review is moved to Thursday afternoon", app: "Slack", title: "General", ago: 7_200)
    try snap(db, "roadmap draft in the same window", app: "Mail", title: "Draft", ago: 7_200)
    let a = ContextAssembler(db: db)
    let c = try await a.context(for: request(field: "Can we confirm the roadmap review", title: "Draft"))
    #expect(c.related.count == 1)
    #expect(c.related[0].app == "Slack" && c.related[0].text.contains("roadmap review"))
    #expect(c.recent.isEmpty)   // older than 30 minutes
}

@Test func recentComesFromOtherWindowsWithinThirtyMinutes() async throws {
    let db = try AppDatabase.inMemory()
    try snap(db, "fresh chat message", app: "Slack", title: "General", ago: 120)
    try snap(db, "same window text", app: "Mail", title: "Draft", ago: 60)
    try snap(db, "stale", app: "Slack", title: "Old", ago: 4_000)
    let c = try await ContextAssembler(db: db).context(for: request(field: "", title: "Draft"))
    #expect(c.recent.map(\.text) == ["fresh chat message"])
}

@Test func styleNoteIsIncluded() async throws {
    let db = try AppDatabase.inMemory()
    try StyleNoteStore(db).upsert(surface: "mail", notes: "Short, tutoiement.", llmCallID: nil, at: now)
    let c = try await ContextAssembler(db: db).context(for: request())
    #expect(c.styleNote == "Short, tutoiement.")
}

@Test func memoryNotAllowedReturnsWindowOnly() async throws {
    let db = try AppDatabase.inMemory()
    try snap(db, "roadmap review notes", ago: 60)
    try StyleNoteStore(db).upsert(surface: "mail", notes: "style", llmCallID: nil, at: now)
    let c = try await ContextAssembler(db: db).context(for: request(field: "roadmap review", live: "window", memory: false))
    #expect(c.windowText == "window" && c.related.isEmpty && c.recent.isEmpty && c.styleNote == nil)
    let none = try await ContextAssembler(db: db).context(for: request(field: "roadmap review", live: nil, memory: false))
    #expect(none == .empty)
}
