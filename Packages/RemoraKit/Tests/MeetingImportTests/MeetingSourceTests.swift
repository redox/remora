import Foundation
import MCP
import Storage
import Testing
@testable import MeetingImport

@Test func onlyLocalAndGranolaEndpointsAreAccepted() throws {
    #expect(try MeetingEndpoint(.quill, "http://127.0.0.1:8090/mcp").url.port == 8090)
    #expect(try MeetingEndpoint(.compatible, "http://[::1]:6060/mcp").url.port == 6060)
    #expect(try MeetingEndpoint(.granola, MeetingEndpoint.granola).url.host() == "mcp.granola.ai")
    for url in ["http://192.168.1.1/mcp", "http://127.0.0.1@example.com/mcp",
                "http://localhost/mcp?token=fake", "file:///tmp/mcp", "https://example.com/mcp"] {
        #expect(throws: MeetingImportError.invalidEndpoint) { try MeetingEndpoint(.compatible, url) }
    }
}

@Test func quillReadsDeclaredMeetingToolsAndPaginates() async throws {
    let fake = FakeMeetingMCP(tools: [
        tool("list_meetings", keys: ["offset", "limit"]),
        tool("get_transcript", keys: ["meetingId"]),
        tool("create_note", keys: ["meetingId"]),
        tool("get_minutes", keys: ["meeting_id", "include_private_notes"]),
    ], replies: [
        ["meetings": [["id": "example-1", "title": "Planning", "start_time": "2026-11-20T15:00:00Z"]],
         "next_offset": 1],
        ["transcript": [["speaker": "Speaker A", "text": "We agreed on Tuesday."]]],
        ["minutes": "Ship it", "private_notes": "Hidden draft."],
        ["meetings": []],
    ])
    let adapter = try await MeetingMCPAdapter(provider: .quill, client: fake)
    let first = try await adapter.page(since: .distantPast, cursor: nil)
    let meeting = try #require(first.meetings.first)
    #expect(try await adapter.body(for: meeting) == "## Notes\nShip it\n\n## Transcript\nSpeaker A: We agreed on Tuesday.")
    _ = try await adapter.page(since: .distantPast, cursor: first.next)
    let calls = await fake.calls
    #expect(calls.map(\.name) == ["list_meetings", "get_transcript", "get_minutes", "list_meetings"])
    #expect(calls[2].arguments["include_private_notes"] == .bool(false))
    #expect(calls[3].arguments["offset"] == .int(1))
}

@Test func granolaParsesMeetingNotesWithoutPrivateNotes() async throws {
    let id = "00000000-0000-4000-8000-000000000001"
    let fake = FakeMeetingMCP(tools: [
        tool("list_meetings", keys: []),
        tool("get_meetings", keys: ["meeting_ids"]),
    ], replies: [
        .string("""
        <meetings_data count="1">
        <meeting id="\(id)" title="Planning" date="Nov 20, 2026 7:30 PM">
          <known_participants>Speaker A</known_participants>
        </meeting>
        </meetings_data>
        """),
        .string("""
        <meetings_data count="1">
        <meeting id="\(id)" title="Planning" date="Nov 20, 2026 7:30 PM">
          <private_notes>Hidden draft.</private_notes>
          <summary>
          Decide Tuesday.
          </summary>
        </meeting>
        </meetings_data>
        """),
    ])
    let adapter = try await MeetingMCPAdapter(provider: .granola, client: fake)
    let page = try await adapter.page(since: .distantPast, cursor: nil)
    let meeting = try #require(page.meetings.first)
    #expect(meeting.id == id)
    #expect(try await adapter.body(for: meeting) == "## Notes\nDecide Tuesday.")
    let calls = await fake.calls
    #expect(calls[1].arguments["meeting_ids"] == .array([.string(id)]))
}

private func tool(_ name: String, keys: [String]) -> Tool {
    Tool(name: name, description: nil,
         inputSchema: .object(["properties": .object(Dictionary(uniqueKeysWithValues: keys.map { ($0, .object([:])) }))]))
}

private actor FakeMeetingMCP: MeetingMCPCalling {
    struct Call: Sendable {
        let name: String
        let arguments: [String: Value]
    }

    let tools: [Tool]
    var replies: [Value]
    private(set) var calls: [Call] = []

    init(tools: [Tool], replies: [Value]) {
        self.tools = tools
        self.replies = replies
    }

    func listTools() async throws -> [Tool] { tools }

    func call(_ name: String, arguments: [String: Value]) async throws -> Value {
        calls.append(Call(name: name, arguments: arguments))
        return replies.removeFirst()
    }
}

@Test func quillReadsTaggedMeetingListsAndTranscripts() async throws {
    let fake = FakeMeetingMCP(tools: [
        tool("meetings_list", keys: ["offset", "limit"]),
        tool("get_meeting_transcript", keys: ["meeting_id"]),
    ], replies: [
        .string("""
            <ToolResponse><meetings count="3" offset="0" limit="2">
            <meeting id="abc" title="Plan &amp; review" date="2026-11-20">
                <summary>We chose option A.</summary>
                <private_notes>Private draft.</private_notes>
            </meeting>
            <meeting id="private" title="Personal" date="2026-11-20" is_private="true" />
            </meetings></ToolResponse>
            """),
        .string("<ToolResponse><transcript><segment speaker=\"Speaker A\">We chose A.</segment></transcript></ToolResponse>"),
    ])
    let adapter = try await MeetingMCPAdapter(provider: .quill, client: fake)
    let page = try await adapter.page(since: .distantPast, cursor: nil)
    #expect(page.meetings.map(\.title) == ["Plan & review"])
    #expect(page.next == .offset(2))
    let meeting = try #require(page.meetings.first)
    #expect(try await adapter.body(for: meeting) == "## Notes\nWe chose option A.\n\n## Transcript\nSpeaker A: We chose A.")
}

@Test func providerBackfillUsesTheProviderDateRangeAndGranolaCursor() async throws {
    let since = Date(timeIntervalSince1970: 1_790_000_000)
    let quill = FakeMeetingMCP(tools: [tool("search_meetings", keys: ["filter", "query"]),
                                      tool("get_transcript", keys: ["meeting_id"])],
                               replies: [["meetings": []]])
    _ = try await MeetingMCPAdapter(provider: .quill, client: quill).page(since: since, cursor: nil)
    let quillCall = try #require(await quill.calls.first)
    #expect(quillCall.arguments["filter"]?.objectValue?["after"] == .string(since.ISO8601Format()))
    #expect(quillCall.arguments["query"] == nil)

    let granola = FakeMeetingMCP(tools: [tool("list_meetings", keys: ["from_date", "time_range", "cursor"]),
                                        tool("get_meetings", keys: ["meeting_ids"])], replies: [
        .string(#"<meetings_data count="0" next_cursor="fixture-page-2"></meetings_data>"#),
        .string(#"<meetings_data count="0"></meetings_data>"#),
    ])
    let adapter = try await MeetingMCPAdapter(provider: .granola, client: granola)
    let page = try await adapter.page(since: since, cursor: nil)
    #expect(page.next == .token("fixture-page-2"))
    _ = try await adapter.page(since: since, cursor: page.next)
    let calls = await granola.calls
    #expect(calls[0].arguments["from_date"] == .string(since.ISO8601Format()))
    #expect(calls[0].arguments["time_range"] == .string("custom"))
    #expect(calls[1].arguments["cursor"] == .string("fixture-page-2"))
}

@Test func granolaReadsTranscriptContinuationByTheSingleMeetingID() async throws {
    let id = "00000000-0000-4000-8000-000000000001"
    let fake = FakeMeetingMCP(tools: [
        tool("list_meetings", keys: []),
        tool("get_meeting_transcript", keys: ["meeting_id", "meeting_ids", "offset"]),
    ], replies: [
        ["meetings": [["id": .string(id), "date": "2026-11-20T10:00:00Z"]]],
        .string("<transcript meeting_id=\"\(id)\" next_offset=\"40\">First excerpt.</transcript>"),
        .string("<transcript meeting_id=\"\(id)\">Second excerpt.</transcript>"),
    ])
    let adapter = try await MeetingMCPAdapter(provider: .granola, client: fake)
    let page = try await adapter.page(since: .distantPast, cursor: nil)
    let meeting = try #require(page.meetings.first)
    #expect(try await adapter.body(for: meeting) == "## Transcript\nFirst excerpt.\nSecond excerpt.")
    let calls = await fake.calls
    #expect(calls[1].arguments["meeting_id"] == .string(id))
    #expect(try #require(calls.dropFirst(2).first).arguments["offset"] == .int(40))
}
