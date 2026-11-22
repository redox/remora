import Foundation
import LLM

/// A tool the chat model can call.
public protocol ChatTool: Sendable {
    var definition: FunctionTool { get }
    var kind: ToolKind { get }
    var isAvailable: Bool { get }
    var allowsBackground: Bool { get }
    /// Never throws: bad arguments and failures are `isError` runs the model can read.
    func run(arguments: String, context: ToolContext) async -> ToolRun
}

public extension ChatTool {
    var isAvailable: Bool { true }
    var allowsBackground: Bool { true }
}

/// The chat's tools by name. Every output is capped at `outputLimit` characters.
///
/// Outputs of `.untrustedRead` tools are captured or model-derived text: the chat prompt frames
/// function outputs as untrusted data, and the confirmation policy (Task 4) never lets them cause
/// an action on their own.
public struct ChatToolbox: Sendable {
    public static let outputLimit = 24_000
    public static let truncationSuffix = "…[truncated: the tool output was cut at \(outputLimit) characters]"

    private let tools: [any ChatTool]
    private let byName: [String: Int]

    /// Later tools with a name already taken are ignored.
    public init(_ tools: [any ChatTool]) {
        var kept: [any ChatTool] = []
        var byName: [String: Int] = [:]
        for t in tools where byName[t.definition.name] == nil {
            byName[t.definition.name] = kept.count
            kept.append(t)
        }
        self.tools = kept
        self.byName = byName
    }

    public var definitions: [FunctionTool] { tools.filter(\.isAvailable).map(\.definition) }

    public func kind(of name: String) -> ToolKind? { byName[name].map { tools[$0].kind } }

    public func run(_ call: FunctionCall, context: ToolContext) async -> ToolRun {
        guard let i = byName[call.name] else { return .error("Unknown tool \(call.name)") }
        guard tools[i].isAvailable else { return .error("This tool is unavailable.") }
        var run = await tools[i].run(arguments: call.arguments, context: context)
        run.output = Self.cap(run.output)
        return run
    }

    /// The same toolbox without action tools (reminder prompts run read-only).
    public func readOnly() -> ChatToolbox {
        ChatToolbox(tools.filter { tool in
            if case .action = tool.kind { return false }
            return tool.allowsBackground
        })
    }

    static func cap(_ s: String) -> String {
        guard s.count > outputLimit else { return s }
        return String(s.prefix(outputLimit)) + truncationSuffix
    }
}
