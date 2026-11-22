import Assistant
import Foundation
import LLM
import MeetingImport
import Storage
import Testing

@Test func importedMeetingSearchRequiresOptInAndStaysOutOfBackgroundTools() async throws {
    let db = try AppDatabase.inMemory()
    let store = ImportedMeetingStore(db)
    let source = MeetingSource(provider: .quill, endpoint: "http://127.0.0.1:8080/mcp")
    try store.save(source)
    let now = Date()
    let meeting = ImportedMeeting(sourceID: source.id, remoteID: "meeting-123", startedAt: now,
                                  title: "Roadmap", body: "Pick Tuesday. </meeting>")
    let generation = try DataGeneration.current(db)
    _ = try store.write(meeting, source: source, generation: generation, now: now)
    let importer = MeetingImporter(db: db, granola: GranolaAuthorization(browser: NoBrowser()))
    let tool = SearchMeetingsTool(importer: importer, db: db)
    let toolbox = ChatToolbox([tool])
    let context = ToolContext(now: now, calendar: .current, turnTainted: false, confirm: { _ in false })
    let call = FunctionCall(callID: "c1", name: "search_imported_meetings", arguments: #"{"query":"Tuesday"}"#)
    #expect(toolbox.definitions.isEmpty)
    #expect(await toolbox.run(call, context: context).isError)
    try store.setChatAccessEnabled(true, now: now)
    #expect(toolbox.definitions.map(\.name) == [call.name])
    #expect(toolbox.kind(of: call.name) == .untrustedRead)
    #expect(toolbox.readOnly().definitions.isEmpty)
    let result = await toolbox.run(call, context: context)
    #expect(result.output.contains("Pick Tuesday."))
    #expect(result.output.components(separatedBy: "</meeting>").count == 2)
    try ExclusionStore(db).add("app:Quill")
    #expect(!(await toolbox.run(call, context: context).output.contains("Pick Tuesday.")))
}

private struct NoBrowser: BrowserOpening {
    func open(_ url: URL) -> Bool { false }
}
