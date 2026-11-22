import Foundation
import LLM
import MCP

/// `get_remora_guide`: how Remora works, from the built-in `FeatureGuide` (static text: a trusted read).
public struct GuideTool: ChatTool {
    public static let outputLimit = 8_000
    static let maxSections = 3
    static let truncationSuffix = "\n…[truncated]"

    public init() {}

    public var kind: ToolKind { .trustedRead }

    public var definition: FunctionTool {
        FunctionTool(
            name: "get_remora_guide",
            description: """
                Remora's built-in guide: how its features, settings, privacy controls and shortcuts \
                work. Call it before explaining Remora. Without a topic it lists the topics.
                """,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "topic": .object(["type": .string("string"),
                                      "description": .string("A topic id or a few words, e.g. reminders, exclusions, dictation")]),
                ]),
                "required": .array([]),
            ]),
            strict: false)
    }

    public func run(arguments: String, context: ToolContext) async -> ToolRun {
        let topic: String?
        do {
            switch try ValueBridge.arguments(arguments)["topic"] {
            case nil, .null?: topic = nil
            case .string(let s)?: topic = s
            default: return .error("topic must be a string.")
            }
        } catch {
            return .error("Invalid arguments: expected a JSON object.")
        }
        let markdown = FeatureGuide.lookup(topic).prefix(Self.maxSections)
            .map { "## \($0.title)\n\n\($0.body)" }.joined(separator: "\n\n")
        return ToolRun(output: Self.cap(markdown), isError: false)
    }

    static func cap(_ s: String) -> String {
        guard s.count > outputLimit else { return s }
        return String(s.prefix(outputLimit - truncationSuffix.count)) + truncationSuffix
    }
}
