import Foundation
import LLM
import MCPServer
import MeetingImport
import Retrieval
import Storage

public struct SearchRecordedMeetingsTool: ChatTool {
    private let db: AppDatabase
    private let library: LocalMeetingLibrary

    public init(db: AppDatabase) {
        self.db = db
        library = LocalMeetingLibrary(db: db)
    }

    public var isAvailable: Bool {
        (try? db.reader.read { try RecordingSearchAccess.chat.allows(in: $0, now: Date()) }) == true
    }
    public var allowsBackground: Bool { false }
    public var kind: ToolKind { .untrustedRead }
    public var definition: FunctionTool {
        let tool = MemoryTools.recordedMeetingDefinition
        return FunctionTool(name: tool.name, description: tool.description,
                            parameters: ValueBridge.toLLM(tool.inputSchema), strict: false)
    }

    public func run(arguments: String, context: ToolContext) async -> ToolRun {
        guard let args = try? ValueBridge.arguments(arguments),
              args["query"] == nil || args["query"]?.stringValue != nil else {
            return .error("Provide meeting keywords or omit the query for recent recordings.")
        }
        let query = args["query"]?.stringValue ?? ""
        guard query.utf8.count <= 256 else { return .error("Use a shorter meeting query.") }
        do {
            guard let hits = try await library.excerpts(query, for: .chat) else {
                return .error("Recorded meetings are unavailable in chat.")
            }
            let tags = ChatPrompt.tags + ["recorded_meetings", "meeting"]
            let output = hits.map { hit in
                let meeting = hit.meeting
                let text = """
                    \(meeting.title.prefix(300)) (\(meeting.client.prefix(80))), \(meeting.startedAt.ISO8601Format())
                    Interrupted: \(meeting.interrupted)
                    Transcript excerpt: \(hit.transcript)
                    Notes excerpt: \(hit.notes ?? "")
                    """
                return "<meeting>\n\(PromptEscaping.escape(text, tags: tags))\n</meeting>"
            }.joined(separator: "\n")
            var result = ToolRun(output: "<recorded_meetings>\n\(output)\n</recorded_meetings>", isError: false)
            result.recordingIDs = Set(hits.map(\.meeting.id))
            return result
        } catch {
            return .error("Could not search recorded meetings.")
        }
    }
}
