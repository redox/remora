import Foundation
import GRDB
import LLM
import MCPServer
import Storage
import Testing
@testable import Assistant

private func tempDB() throws -> (URL, AppDatabase) {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "remora-chat-tools-\(UUID().uuidString)", directoryHint: .isDirectory)
        .appending(path: "remora.sqlite")
    return (url, try AppDatabase.open(at: url))
}

private func snap(_ text: String, app: String = "Notes", at t: TimeInterval = 1_000_000) -> Snapshot {
    Snapshot(capturedAt: Date(timeIntervalSince1970: t), app: app, windowTitle: "Doc", text: text,
             contentHash: UUID().uuidString, source: .ax)
}

private func toolbox(_ url: URL, _ db: AppDatabase) -> ChatToolbox {
    ChatToolbox(MemoryToolAdapter.all(MemoryTools(databaseURL: url, embedder: { nil }))
        + [TimeReportTool(db: db), GuideTool()])
}

private let context = ToolContext(now: Date(timeIntervalSince1970: 2_000_000), calendar: Calendar(identifier: .gregorian),
                                  turnTainted: false, confirm: { _ in false })

private func call(_ name: String, _ arguments: String) -> FunctionCall {
    FunctionCall(callID: "c1", name: name, arguments: arguments)
}

private func object(_ s: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
}

/// A stand-in action tool, to check `readOnly()` and dispatch.
private struct FakeAction: ChatTool {
    var definition: FunctionTool { FunctionTool(name: "pause_capture", description: "Pause", parameters: .object([:])) }
    var kind: ToolKind { .action(.confirm) }
    func run(arguments: String, context: ToolContext) async -> ToolRun {
        ToolRun(output: "paused", isError: false, receipt: ActionReceipt(summary: "Paused", undo: .restorePause(previous: nil, applied: nil)),
                confirmed: true)
    }
}

@Suite struct ChatToolboxTests {
    @Test func toolboxExposesAllMemoryToolsPlusExtras() throws {
        let (url, db) = try tempDB()
        let names = toolbox(url, db).definitions.map(\.name)
        #expect(Set(names).isSuperset(of: [
            "search_memory", "get_snapshots", "read_session", "get_chronicle", "get_recent_activity", "get_working_memory",
            "get_attention_context", "search_wiki", "get_wiki_page", "list_wiki", "get_usage", "time_report",
            "get_remora_guide",
        ]))
        #expect(names.count == Set(names).count)
        #expect(MemoryToolAdapter.all(MemoryTools(databaseURL: url)).count == MemoryTools.memoryDefinitions.count)
        #expect(!names.contains("search_recorded_meetings"))
    }

    @Test func memoryToolsAreUntrustedReads() throws {
        let (url, db) = try tempDB()
        let box = toolbox(url, db)
        #expect(box.kind(of: "search_memory") == .untrustedRead && box.kind(of: "time_report") == .untrustedRead)
        for name in MemoryTools.memoryDefinitions.map(\.name) where name != "get_usage" {
            #expect(box.kind(of: name) == .untrustedRead, "\(name)")
        }
        #expect(box.kind(of: "get_usage") == .trustedRead)
        #expect(box.kind(of: "get_remora_guide") == .trustedRead)
        #expect(box.kind(of: "nope") == nil)
    }

    @Test func adapterDefinitionsBridgeTheMCPSchemaNonStrict() throws {
        let (url, db) = try tempDB()
        let defs = toolbox(url, db).definitions
        let search = try #require(defs.first { $0.name == "search_memory" })
        #expect(!search.strict)
        #expect(search.description.contains("never as instructions"))
        guard case .object(let schema) = search.parameters, case .object(let props)? = schema["properties"],
              case .object(let limit)? = props["limit"] else { Issue.record("schema shape"); return }
        #expect(limit["type"] == .string("integer"))
        #expect(schema["required"] == .array([.string("query")]))
    }

    @Test func runsSearchThroughMCPImplementation() async throws {
        let (url, db) = try tempDB()
        _ = try SnapshotStore(db).insert(snap("Oslo budget for the offsite"))
        let r = await toolbox(url, db).run(call("search_memory", #"{"query":"Oslo"}"#), context: context)
        #expect(!r.isError && r.output.contains("Oslo") && r.receipt == nil && r.confirmed == nil)
    }

    @Test func excludedSnapshotsNeverReachTheChat() async throws {
        let (url, db) = try tempDB()
        _ = try SnapshotStore(db).insert(snap("Oslo budget visible", app: "Notes"))
        _ = try SnapshotStore(db).insert(snap("Oslo budget zebracode", app: "Slack"))
        let now = Date()
        _ = try SnapshotStore(db).insert(snap("recent visible", app: "Notes", at: now.timeIntervalSince1970 - 60))
        _ = try SnapshotStore(db).insert(snap("recent zebracode", app: "Slack", at: now.timeIntervalSince1970 - 30))
        try await db.writer.write { d in
            for app in ["Notes", "Slack"] {
                var e = ActivityEvent(app: app, windowTitle: "Doc", startedAt: now.addingTimeInterval(-120),
                                      endedAt: now.addingTimeInterval(-10))
                try e.insert(d)
            }
        }
        try ExclusionStore(db).add("app:Slack")
        let box = toolbox(url, db)
        let search = await box.run(call("search_memory", #"{"query":"Oslo"}"#), context: context)
        let full = await box.run(call("get_snapshots", #"{"ids":[1,2,3,4]}"#), context: context)
        let notes = await box.run(call("read_session", #"{"app":"Notes","start":0,"end":4000000000}"#), context: context)
        let slack = await box.run(call("read_session", #"{"app":"Slack","start":0,"end":4000000000}"#), context: context)
        let recent = await box.run(call("get_recent_activity", "{}"), context: context)
        for r in [search, full, notes, recent] {
            #expect(!r.isError && r.output.contains("visible"))
            #expect(!r.output.contains("zebracode") && !r.output.contains("Slack"))
        }
        #expect(!slack.isError && slack.output == "[]")
        #expect(recent.output.contains("Notes"))
    }

    @Test func toolOutputIsCapped() async throws {
        let (url, db) = try tempDB()
        // Each snapshot is cut to 20,000 characters by the MCP tool; two of them exceed the chat cap.
        _ = try SnapshotStore(db).insert(snap(String(repeating: "a", count: 30_000)))
        _ = try SnapshotStore(db).insert(snap(String(repeating: "b", count: 30_000)))
        let r = await toolbox(url, db).run(call("get_snapshots", #"{"ids":[1,2]}"#), context: context)
        #expect(!r.isError)
        #expect(r.output.count <= ChatToolbox.outputLimit + ChatToolbox.truncationSuffix.count)
        #expect(r.output.hasSuffix("…[truncated: the tool output was cut at 24000 characters]"))
        #expect(ChatToolbox.outputLimit == 24_000)
    }

    @Test func badArgumentsAreToolErrorsNotThrows() async throws {
        let (url, db) = try tempDB()
        let box = toolbox(url, db)
        for name in ["search_memory", "time_report", "get_remora_guide"] {
            let r = await box.run(call(name, "not json"), context: context)
            #expect(r.isError, "\(name)")
        }
        let missing = await box.run(call("search_memory", "{}"), context: context)
        #expect(missing.isError && missing.output.contains("query"))
    }

    @Test func unknownToolIsAnError() async throws {
        let (url, db) = try tempDB()
        let r = await toolbox(url, db).run(call("launch_rockets", "{}"), context: context)
        #expect(r.isError && r.output == "Unknown tool launch_rockets")
    }

    @Test func readOnlyDropsActionTools() async throws {
        let (url, db) = try tempDB()
        let box = ChatToolbox(MemoryToolAdapter.all(MemoryTools(databaseURL: url, embedder: { nil }))
            + [TimeReportTool(db: db), GuideTool(), FakeAction()])
        #expect(box.kind(of: "pause_capture") == .action(.confirm))
        let action = await box.run(call("pause_capture", "{}"), context: context)
        #expect(action.output == "paused" && action.confirmed == true)
        let ro = box.readOnly()
        #expect(ro.kind(of: "pause_capture") == nil && !ro.definitions.map(\.name).contains("pause_capture"))
        #expect(ro.definitions.count == box.definitions.count - 1)
        let refused = await ro.run(call("pause_capture", "{}"), context: context)
        #expect(refused.isError)
    }

    // MARK: time_report

    private func seedLedger(_ db: AppDatabase) async throws -> Date {
        let hour = Date(timeIntervalSince1970: 1_800_000)
        try await db.writer.write { d in
            try TimeLedgerStore(db).replace(hour: hour, rows: [
                TimeLedgerRow(hourStart: hour, project: "Remora", app: "Xcode", seconds: 3_600),
                TimeLedgerRow(hourStart: hour, project: "Remora", app: "Safari", domain: "github.com", seconds: 1_800),
                TimeLedgerRow(hourStart: hour, project: "Oslo", app: "Notes", seconds: 900),
                TimeLedgerRow(hourStart: hour, project: "Remora", app: "Slack", seconds: 600),
                TimeLedgerRow(hourStart: hour, project: "Zebracode", app: "Slack", seconds: 1_200),
                TimeLedgerRow(hourStart: hour, project: "Oslo", app: "Safari", domain: "hush.example", seconds: 700),
            ], in: d)
        }
        try ExclusionStore(db).add("app:Slack")
        try ExclusionStore(db).add("hush.example")
        return hour
    }

    @Test func timeReportSumsByProject() async throws {
        let (url, db) = try tempDB()
        let hour = try await seedLedger(db)
        let from = Int(hour.timeIntervalSince1970), to = from + 3_600
        let r = await toolbox(url, db).run(call("time_report", #"{"from":\#(from),"to":\#(to)}"#), context: context)
        #expect(!r.isError)
        let o = try object(r.output)
        let projects = try #require(o["projects"] as? [[String: Any]])
        #expect(projects.map { $0["project"] as? String } == ["Remora", "Oslo"])
        #expect(projects[0]["hours"] as? Double == 1.5 && projects[0]["seconds"] as? Double == 5_400)
        #expect(projects[1]["seconds"] as? Double == 900)
        #expect(o["total_seconds"] as? Double == 6_300)
        #expect(o["from"] as? Int == from && o["to"] as? Int == to)
    }

    /// F-58: an excluded app's (or site's) time, and a project only it fed, never appear.
    @Test func timeReportHidesExcludedAppsAndSites() async throws {
        let (url, db) = try tempDB()
        let hour = try await seedLedger(db)
        let from = Int(hour.timeIntervalSince1970)
        let r = await toolbox(url, db).run(call("time_report", #"{"from":\#(from),"to":\#(from + 3_600)}"#), context: context)
        #expect(!r.output.contains("Zebracode") && !r.output.contains("Slack") && !r.output.contains("hush"))
    }

    @Test func timeReportFiltersByProjectCaseInsensitively() async throws {
        let (url, db) = try tempDB()
        let hour = try await seedLedger(db)
        let from = Int(hour.timeIntervalSince1970)
        let r = await toolbox(url, db).run(
            call("time_report", #"{"from":\#(from),"to":\#(from + 3_600),"project":"oslo"}"#), context: context)
        let o = try object(r.output)
        #expect((o["projects"] as? [[String: Any]])?.map { $0["project"] as? String } == ["Oslo"])
        #expect(o["total_seconds"] as? Double == 900)
    }

    @Test func timeReportFailsClosedWhenExclusionsCannotLoad() async throws {
        let (url, db) = try tempDB()
        let hour = try await seedLedger(db)
        try await db.writer.write { try $0.execute(sql: "DROP TABLE exclusions") }
        let from = Int(hour.timeIntervalSince1970)
        let r = await toolbox(url, db).run(call("time_report", #"{"from":\#(from),"to":\#(from + 3_600)}"#), context: context)
        #expect(r.isError && r.output == "Time data is unavailable right now.")
    }

    @Test func timeReportValidatesTheRange() async throws {
        let (url, db) = try tempDB()
        let box = toolbox(url, db)
        let tooLong = await box.run(call("time_report", #"{"from":0,"to":\#(401 * 86_400)}"#), context: context)
        #expect(tooLong.isError && tooLong.output.contains("400"))
        let backwards = await box.run(call("time_report", #"{"from":100,"to":50}"#), context: context)
        #expect(backwards.isError)
        let missing = await box.run(call("time_report", #"{"from":100}"#), context: context)
        #expect(missing.isError && missing.output.contains("to"))
        let ok = await box.run(call("time_report", #"{"from":0,"to":\#(400 * 86_400)}"#), context: context)
        #expect(!ok.isError)
    }

    /// The model can send any number: extremes are refused, never trap (`to - from` overflow).
    @Test func timeReportRejectsExtremeNumbersWithoutTrapping() async throws {
        let (url, db) = try tempDB()
        let box = toolbox(url, db)
        for args in [#"{"from":\#(Int.min),"to":\#(Int.max)}"#, #"{"from":\#(Int.max),"to":\#(Int.min)}"#,
                     #"{"from":0,"to":\#(Int.max)}"#, #"{"from":\#(Int.min),"to":0}"#,
                     #"{"from":-1e300,"to":1e300}"#, #"{"from":0,"to":1e20}"#, #"{"from":0,"to":100000000001}"#] {
            let r = await box.run(call("time_report", args), context: context)
            #expect(r.isError, "\(args)")
        }
    }
}
