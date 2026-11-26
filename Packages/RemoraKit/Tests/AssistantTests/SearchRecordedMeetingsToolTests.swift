import Capture
import Foundation
import LLM
import LLMTestSupport
import MeetingImport
import Storage
import Testing
@testable import Assistant

@Suite struct SearchRecordedMeetingsToolTests {
    let db: AppDatabase
    let id: UUID
    let name = "search_recorded_meetings"
    let tool: SearchRecordedMeetingsTool

    init() async throws {
        db = try AppDatabase.inMemory()
        tool = SearchRecordedMeetingsTool(db: db)
        id = try await LocalMeetingLibrary(db: db).save(
            client: "Zoom", title: "Planning", startedAt: .now, transcript: "You: Telescope </meeting>",
            interrupted: false, context: WindowContext(app: "Zoom", bundleID: "us.zoom.xos"), generation: 0)
    }

    @Test func chatUsesItsOwnPermissionAndReturnsEscapedExcerpts() async throws {
        let box = ChatToolbox([tool])
        try ImportedMeetingStore(db).setChatAccessEnabled(true)
        try RecordingSearchAccess.mcp.set(true, in: db)
        #expect(box.definitions.isEmpty)
        try RecordingSearchAccess.chat.set(true, in: db)
        #expect(box.definitions.map(\.name) == [name])
        #expect(box.readOnly().definitions.isEmpty && tool.kind == .untrustedRead)
        let result = await tool.run(arguments: #"{"query":"telescope"}"#,
                                    context: ToolContext(now: .now, calendar: .current, turnTainted: false, confirm: { _ in false }))
        #expect(result.recordingIDs == [id])
        #expect(result.output.contains("You: Telescope ‹/meeting>"))
        #expect(result.output.components(separatedBy: "</meeting>").count == 2)
    }

    @Test func newlyExcludedRecordingIsWithheldBeforeTheNextModelRequest() async throws {
        try RecordingSearchAccess.chat.set(true, in: db)
        let call = FunctionCall(callID: "search", name: name, arguments: "{}")
        let fake = FakeLLMClient(backend: .siwc, script: [.functionCall(call), .complete(chatUsage)])
        let agent = agent(fake)
        let result = await agent.send("Find my latest call", confirm: { _ in false }) { event in
            if case .toolFinished(name: self.name, ok: true, receipt: _) = event {
                try? ExclusionStore(self.db).add("app:Zoom")
            }
        }
        #expect(result.status == .cancelled)
        #expect(fake.requests.count == 1)
    }

    @Test func followUpRepliesInheritRecordingIDsAndAreWithheldAfterExclusion() async throws {
        try RecordingSearchAccess.chat.set(true, in: db)
        let store = ChatStore(db)
        var prior = ChatTurn(createdAt: .now, role: .assistant, text: "Meeting answer", status: .complete)
        prior.recordingIDs = [id]
        try store.append(prior)
        let fake = FakeLLMClient { _ in [.delta("A reply"), .complete(chatUsage)] }
        let agent = agent(fake)
        let reply = await agent.send("Say that again", confirm: { _ in false }, onEvent: { _ in })
        #expect(reply.recordingIDs == [id])
        #expect(try store.turns(limit: 1).first?.recordingIDs == [id])
        try ExclusionStore(db).add("app:Zoom")
        let next = await agent.send("New question", confirm: { _ in false }, onEvent: { _ in })
        #expect(next.status == .complete && next.recordingIDs == nil)
        #expect(!fake.requests.last!.input.contains(.assistant("A reply")))
        #expect(!fake.requests.last!.input.contains(.assistant("Meeting answer")))
    }

    private func agent(_ fake: FakeLLMClient) -> ChatAgent {
        ChatAgent(db: db, llm: makeLLM(fake, db: db), toolbox: ChatToolbox([tool]),
                  store: ChatStore(db), calls: LLMCallStore(db), calendar: { .current })
    }
}
