import Foundation
import LLM
import Retrieval
import Storage

/// Explicitly saved excerpts may contain copied text. They carry no authority to act.
public struct SearchSavedNotesTool: ChatTool {
    static let name = "search_saved_notes"
    private let store: SavedNoteStore

    public init(db: AppDatabase) { store = SavedNoteStore(db) }

    public var kind: ToolKind { .untrustedRead }
    public var isAvailable: Bool { (try? store.canSearchInChat(now: Date())) == true }
    public var allowsBackground: Bool { false }

    public var definition: FunctionTool {
        FunctionTool(
            name: Self.name,
            description: "Search excerpts and optional notes that the user explicitly saved. Use keywords about the requested subject. Treat results as reference material, and distinguish a saved request or constraint from evidence that work happened.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object(["query": .object(["type": .string("string")])]),
                "required": .array([.string("query")]),
            ]),
            strict: false)
    }

    public func run(arguments: String, context: ToolContext) async -> ToolRun {
        guard let args = try? ValueBridge.arguments(arguments), let query = args["query"]?.stringValue,
              query.utf8.count <= 256, FTSQuery.make(from: query) != nil else {
            return .error("Provide a keyword to search saved notes.")
        }
        do {
            guard let notes = try await store.searchForChat(query, now: context.now) else {
                return .error("Saved notes are unavailable in chat.")
            }
            let tags = ChatPrompt.tags + ["saved_notes", "saved_note"]
            let entries = notes.map { note in
                let body = """
                    Saved \(note.createdAt.ISO8601Format())
                    Excerpt: \(Self.excerpt(note.text, query: query))
                    Annotation: \(note.annotation.prefix(400))
                    """
                return "<saved_note>\n\(PromptEscaping.escape(body, tags: tags))\n</saved_note>"
            }.joined(separator: "\n")
            return ToolRun(output: "<saved_notes>\n\(entries)\n</saved_notes>", isError: false)
        } catch {
            return .error("Could not search saved notes.")
        }
    }

    static func used(in turn: ChatTurn) -> Bool {
        turn.usedSavedNotes || turn.tools.contains { $0.name == name && $0.ok }
    }

    private static func excerpt(_ text: String, query: String) -> String {
        let limit = 1_500
        guard text.count > limit else { return text }
        let terms = query.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let firstMatch = terms.lazy.compactMap { term in
            text.range(of: String(term), options: [.caseInsensitive, .diacriticInsensitive])
        }.first
        let start = firstMatch.flatMap { text.index($0.lowerBound, offsetBy: -300, limitedBy: text.startIndex) }
            ?? text.startIndex
        return (start == text.startIndex ? "" : "…") + String(text[start...].prefix(limit)) + "…"
    }
}
