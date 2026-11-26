import Foundation
import LLM
import MCP
import MCPServer

/// One of the MCP server's memory tools, for the chat. The implementation, its exclusion
/// filtering (fresh `SnapshotPolicy`, `.denyAll` on failure), `DerivedPolicy` on derived rows,
/// `generated_by` and result caps are the MCP server's own (`MemoryTools.call`): nothing is
/// re-implemented here.
public struct MemoryToolAdapter: ChatTool {
    public let definition: FunctionTool
    public let kind: ToolKind
    private let tools: MemoryTools

    /// Tools that return only Remora's own bookkeeping, no captured or derived text.
    static let trustedNames: Set<String> = ["get_usage"]

    init(_ d: ToolDefinition, tools: MemoryTools) {
        // Optional parameters: the schemas are not strict-mode schemas.
        definition = FunctionTool(name: d.name, description: d.description, parameters: ValueBridge.toLLM(d.inputSchema),
                                  strict: false)
        kind = Self.trustedNames.contains(d.name) ? .trustedRead : .untrustedRead
        self.tools = tools
    }

    /// One adapter per `MemoryTools.memoryDefinitions` entry, in order.
    public static func all(_ tools: MemoryTools) -> [MemoryToolAdapter] {
        MemoryTools.memoryDefinitions.map { MemoryToolAdapter($0, tools: tools) }
    }

    public func run(arguments: String, context: ToolContext) async -> ToolRun {
        let args: [String: MCP.Value]
        do { args = try ValueBridge.arguments(arguments) } catch {
            return .error("Invalid arguments: expected a JSON object.")
        }
        let result = await tools.call(definition.name, arguments: args)
        return ToolRun(output: result.text, isError: result.isError)
    }
}
