import Foundation
import MCP
import Storage

public enum RemoraMCPServer {
    /// Runs the stdio MCP server until the client disconnects. Only JSON-RPC goes to stdout.
    public static func run(databaseURL: URL) async throws {
        let tools = MemoryTools(databaseURL: databaseURL)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let server = Server(
            name: "remora", version: version,
            instructions: MemoryTools.serverInstructions,
            capabilities: .init(tools: .init(listChanged: false)))

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: MemoryTools.definitions.map {
                Tool(name: $0.name, description: $0.description, inputSchema: $0.inputSchema,
                     annotations: .init(readOnlyHint: true, destructiveHint: false, openWorldHint: false))
            })
        }
        await server.withMethodHandler(CallTool.self) { params in
            let r = await tools.call(params.name, arguments: params.arguments ?? [:])
            return CallTool.Result(content: [.text(text: r.text, annotations: nil, _meta: nil)], isError: r.isError)
        }

        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }
}
