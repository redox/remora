import Foundation
import MCP
import MCPServer
import Storage
import Testing

private let january5 = 1_767_614_400 // 2026-01-05 at noon UTC.
private let day = 86_400

private func capture(_ id: Int64, _ dayOffset: Int, _ text: String, app: String = "Notes") -> Snapshot {
    Snapshot(id: id, capturedAt: Date(timeIntervalSince1970: Double(january5 + dayOffset * day)),
             app: app, text: text, contentHash: "fixture-\(id)", source: .ax)
}

/// IDs stay fixed so ranks can be compared between revisions, even if a new capture is added.
private let history = [
    capture(1, 0, "Kestrel release approved for Friday."),
    capture(2, 1, "Kestrel release moved from Friday to Monday. Schedule change approved."),
    capture(3, 1, "Could we ship the Plover release on Friday?"),
    capture(4, 0, "Kestrel budget approved at 12,000."),
    capture(5, 2, "Kestrel budget increased to 15,000 to cover localization.", app: "Mail"),
    capture(6, 1, "Plover budget approved at 8,000."),
    capture(7, 0, "Répétition Kestrel prévue dans la salle Indigo."),
    capture(8, 1, "Kestrel handoff owner is Mira. Theo will review.", app: "Mail"),
    capture(9, 2, "Plover handoff owner is Theo. Mira will review.", app: "Mail"),
    capture(10, 2, "Kestrel rehearsal room booked in Cedar.", app: "Mail"),
    capture(11, 2, "Kestrel rehearsal room booked in Birch."),
    capture(12, 3, "The Plover release is approved for Friday.", app: "Private Notes"),
    capture(13, 2, "Kestrel release checklist still needs the screenshots from the localization team."),
    capture(14, 1, "Kestrel release artwork is waiting for a review from the design team."),
    capture(15, 3, "Please send the Kestrel release captions to the accessibility reviewer when ready."),
    capture(16, 2, "We archived the Kestrel release test recordings with the rest of the project."),
    capture(17, 0, "Please bring the Kestrel budget worksheet to the review."),
    capture(18, 1, "File the Kestrel budget template with the planning documents."),
    capture(19, 2, "Plover needs a budget review before localization begins.", app: "Mail"),
    capture(20, 3, "Kestrel budget receipts from the release lunch are ready for filing."),
    capture(21, 3, "Has anyone saved the blank Kestrel budget forecast for our next meeting?"),
]

private struct Probe {
    let question: String
    let query: String
    let sources: [Int]
    var filters: [String: Value] = [:]
    var forbidden: [Int] = []
    var insufficient = false
}

private let probes = [
    Probe(question: "Did Friday remain the approved Kestrel ship date?", query: "Kestrel release", sources: [1, 2]),
    Probe(question: "Did we decide to ship Plover on Friday?", query: "Plover release", sources: [3],
          forbidden: [1, 2], insufficient: true),
    Probe(question: "What changed in the Kestrel budget?", query: "Kestrel budget", sources: [4, 5]),
    Probe(question: "What Kestrel budget had we approved by January 5?", query: "Kestrel budget", sources: [4],
          filters: ["until": .int(january5)], forbidden: [5]),
    Probe(question: "Which Kestrel budget update came in by mail from January 7 onward?", query: "Kestrel budget", sources: [5],
          filters: ["since": .int(january5 + 2 * day), "app": "Mail"], forbidden: [4, 6]),
    Probe(question: "How much was the Plover budget?", query: "Plover budget", sources: [6]),
    Probe(question: "Où aura lieu la répétition Kestrel ?", query: "repetition Kestrel", sources: [7]),
    Probe(question: "Who owns the Kestrel handoff and who reviews it?", query: "Kestrel handoff", sources: [8], forbidden: [9]),
    Probe(question: "Who owns the Plover handoff?", query: "Plover handoff", sources: [9], forbidden: [8]),
    Probe(question: "Which rehearsal room is confirmed for Kestrel?", query: "Kestrel rehearsal room",
          sources: [10, 11], insufficient: true),
    Probe(question: "Which room does the Kestrel rehearsal email name?", query: "Kestrel rehearsal room",
          sources: [10], filters: ["app": "Mail"], forbidden: [11]),
    Probe(question: "Who approved the Kestrel catering order?", query: "Kestrel catering", sources: [], insufficient: true),
]

private struct SearchHit: Decodable {
    let id: Int
}

private struct FetchedSource: Decodable {
    let id: Int
    let capturedAt: Int
    let text: String
}

@Test func recallBenchmarkFindsTheExpectedEvidenceInFiveHits() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "remora.sqlite")
    let db = try AppDatabase.open(at: url)
    for snapshot in history {
        _ = try SnapshotStore(db).insert(snapshot)
    }
    try ExclusionStore(db).add("app:Private Notes")
    let tools = MemoryTools(databaseURL: url, embedder: { nil })
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase

    for probe in probes {
        var arguments = probe.filters
        arguments["query"] = .string(probe.query)
        arguments["limit"] = 5
        let search = await tools.call("search_memory", arguments: arguments)
        try #require(!search.isError, "\(probe.question)")
        let ids = try decoder.decode([SearchHit].self, from: Data(search.text.utf8)).map(\.id)
        let ranks = probe.sources.map { id in
            ids.firstIndex(of: id).map { "#\(id)@\($0 + 1)" } ?? "#\(id)@miss"
        }
        let disposition = probe.insufficient ? "insufficient" : "answerable"
        let sourceRanks = ranks.isEmpty ? "none expected" : ranks.joined(separator: ",")
        print("recall@5 \(probe.question) | \(disposition) | sources \(sourceRanks) | hits \(ids)")
        #expect(ids.count <= 5 && Set(ids).count == ids.count)
        #expect(Set(probe.sources).isSubset(of: ids), "\(probe.question) — \(ranks)")
        #expect(Set(probe.forbidden + [12]).isDisjoint(with: ids), "\(probe.question) — \(ids)")
        if probe.sources.isEmpty { #expect(ids.isEmpty, "\(probe.question)") }
        guard !ids.isEmpty else { continue }

        let fetched = await tools.call("get_snapshots", arguments: ["ids": .array(ids.map(Value.int))])
        try #require(!fetched.isError, "\(probe.question)")
        let rows = try decoder.decode([FetchedSource].self, from: Data(fetched.text.utf8))
        #expect(Set(rows.map(\.id)) == Set(ids))
        for row in rows {
            let source = try #require(history.first { $0.id == Int64(row.id) })
            #expect(row.text == source.text && row.capturedAt == Int(source.capturedAt.timeIntervalSince1970))
        }
    }
}
