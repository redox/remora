import Foundation
import MCP

struct MeetingMCPClient: MeetingMCPCalling {
    private let client = Client(name: "Remora", version: "1.0")

    static func connect(endpoint: URL, token: String?) async throws -> Self {
        let connection = Self()
        do {
            _ = try await withTaskCancellationHandler {
                try await connection.client.connect(transport: MeetingHTTPTransport(endpoint: endpoint, token: token))
            } onCancel: {
                Task { await connection.close() }
            }
            return connection
        } catch {
            await connection.close()
            throw error
        }
    }

    func close() async { await client.disconnect() }

    func listTools() async throws -> [Tool] {
        var result: [Tool] = []
        var cursor: String?
        for _ in 0..<16 {
            let nextPage = cursor
            let page = try await withTaskCancellationHandler {
                try await client.listTools(cursor: nextPage)
            } onCancel: {
                Task { await close() }
            }
            result += page.tools
            guard let next = page.nextCursor else { return result }
            guard cursor != next, next.utf8.count <= 2048 else { break }
            cursor = next
        }
        throw MeetingImportError.invalidResponse
    }

    func call(_ name: String, arguments: [String: Value]) async throws -> Value {
        let request = try await client.send(CallTool.request(.init(name: name, arguments: arguments)))
        let result = try await withTaskCancellationHandler {
            try await request.value
        } onCancel: {
            Task { await close() }
        }
        let text = result.content.compactMap { block -> String? in
            guard case .text(let text, _, _) = block else { return nil }
            return text
        }.joined(separator: "\n")
        if result.isError == true {
            let reason = String(text.prefix(500)).lowercased()
            if ["rate limit", "rate_limit", "too many requests"].contains(where: reason.contains) {
                throw MeetingImportError.httpStatus(429)
            }
            if ["paid granola", "paid plan", "paid tier", "not available on your plan",
                "no transcript available", "transcript not found", "no minutes available"].contains(where: reason.contains) {
                throw MeetingImportError.toolUnavailable
            }
            throw MeetingImportError.toolFailed
        }
        if let structured = result.structuredContent { return structured }
        return (try? JSONDecoder().decode(Value.self, from: Data(text.utf8))) ?? .string(text)
    }
}
