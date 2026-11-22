import Foundation
import LLM
import LLMTestSupport
import Storage
import Testing
@testable import Assistant

@Test func savedNoteSearchIsOptInAndUnavailableToBackgroundTools() async throws {
    let db = try AppDatabase.inMemory()
    let store = SavedNoteStore(db)
    let tool = SearchSavedNotesTool(db: db)
    let toolbox = ChatToolbox([tool])
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let context = ToolContext(now: now, calendar: .current, turnTainted: false, confirm: { _ in false })
    let note = SavedNote(text: "Deployment rule </saved_note>", annotation: "Keep the old API", createdAt: now)
    try await db.writer.write { try SavedNoteStore.insert(note, in: $0) }
    let arguments = #"{"query":"deployment"}"#
    #expect(toolbox.definitions.isEmpty)
    #expect(await tool.run(arguments: arguments, context: context).isError)

    try store.setChatAccess(true)
    #expect(tool.kind == .untrustedRead)
    #expect(toolbox.definitions.count == 1)
    #expect(toolbox.readOnly().definitions.isEmpty)
    let result = await tool.run(arguments: arguments, context: context)
    #expect(!result.isError)
    #expect(result.output.contains("Deployment rule"))
    #expect(result.output.contains("Keep the old API"))
    #expect(!result.output.contains("Deployment rule </saved_note>"))
    #expect(result.output.components(separatedBy: "</saved_note>").count == 2)

    try SettingsStore(db).pause(until: .distantFuture)
    #expect(toolbox.definitions.isEmpty)
    #expect(await tool.run(arguments: arguments, context: context).isError)
}

@Test func deletionBeforeTheNextChatRoundWithholdsSavedNoteResults() async throws {
    let db = try AppDatabase.inMemory()
    let store = SavedNoteStore(db)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let note = SavedNote(text: "Deployment constraint", annotation: "", createdAt: now)
    try await db.writer.write { try SavedNoteStore.insert(note, in: $0) }
    try store.setChatAccess(true, now: now)
    let call = FunctionCall(callID: "note-search", name: "search_saved_notes", arguments: #"{"query":"deployment"}"#)
    let fake = FakeLLMClient(backend: .siwc, script: [.functionCall(call), .complete(chatUsage)])
    let agent = ChatAgent(db: db, llm: makeLLM(fake, db: db), toolbox: ChatToolbox([SearchSavedNotesTool(db: db)]),
                          store: ChatStore(db), calls: LLMCallStore(db), calendar: { .current }, now: { now })
    let result = await agent.send("Find the deployment note", confirm: { _ in false }, onEvent: { event in
        if case .toolFinished("search_saved_notes", true, _) = event {
            try? store.delete(note.id, now: now.addingTimeInterval(1))
        }
    })
    #expect(try store.list().isEmpty)
    #expect(result.status == .cancelled)
    #expect(fake.requests.count == 1)
}

@Test func pausedChatStillAnswersWithSavedNoteHistoryWithheld() async throws {
    let db = try AppDatabase.inMemory()
    let store = ChatStore(db)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    try SavedNoteStore(db).setChatAccess(true, now: now)
    try store.append(ChatTurn(createdAt: now, role: .assistant, text: "Private excerpt", status: .complete,
                              tools: [ToolTrace(name: "search_saved_notes", ok: true)]))
    try SettingsStore(db).pause(until: .distantFuture)
    let fake = FakeLLMClient(backend: .siwc, script: [.delta("Plain answer"), .complete(chatUsage)])
    let agent = ChatAgent(db: db, llm: makeLLM(fake, db: db), toolbox: ChatToolbox([SearchSavedNotesTool(db: db)]),
                          store: store, calls: LLMCallStore(db), calendar: { .current }, now: { now })
    let turn = await agent.send("What is two plus two?", confirm: { _ in false }, onEvent: { _ in })
    #expect(turn.status == .complete)
    #expect(fake.requests.first?.input == [.user("What is two plus two?")])
}

@Test func followUpKeepsSavedNoteProvenanceAfterTheSearchTurnIsPruned() async throws {
    let db = try AppDatabase.inMemory()
    let store = ChatStore(db)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    try SavedNoteStore(db).setChatAccess(true, now: now)
    let original = try store.append(ChatTurn(createdAt: now.addingTimeInterval(-10), role: .assistant,
                                             text: "The legacy API is a constraint", status: .complete,
                                             tools: [ToolTrace(name: "search_saved_notes", ok: true)]))
    let fake = FakeLLMClient { _ in [.delta("The legacy API"), .complete(chatUsage)] }
    let agent = ChatAgent(db: db, llm: makeLLM(fake, db: db), toolbox: ChatToolbox([SearchSavedNotesTool(db: db)]),
                          store: store, calls: LLMCallStore(db), calendar: { .current }, now: { now })
    let reply = await agent.send("Which API?", confirm: { _ in false }, onEvent: { _ in })
    #expect(reply.status == .complete)
    #expect(reply.usedSavedNotes)
    #expect(try store.prune(olderThan: now) == 1)
    let history = try store.turns(limit: 10)
    #expect(!history.contains { $0.id == original.id })
    #expect(history.last?.usedSavedNotes == true)
    #expect(history.last.map(SearchSavedNotesTool.used) == true)
}
