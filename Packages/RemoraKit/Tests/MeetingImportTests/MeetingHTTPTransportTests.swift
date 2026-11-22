import Foundation
import MCP
import Testing
@testable import MeetingImport

@Test func streamableHTTPNegotiatesProtocolAndKeepsTheSession() async throws {
    let endpoint = try #require(URL(string: "http://127.0.0.1:8899/mcp"))
    let fixtureSession: @Sendable () -> URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MeetingHTTPFixture.self]
        return URLSession(configuration: config)
    }
    let client = Client(name: "Remora", version: "1.0")
    do {
        try await client.connect(transport: MeetingHTTPTransport(endpoint: endpoint, token: nil, session: fixtureSession(),
                                                                     makeCleanupSession: fixtureSession))
        let tools = try await client.listTools()
        #expect(tools.tools.map(\.name) == ["list_meetings"])
        await client.disconnect()
    } catch {
        await client.disconnect()
        throw error
    }
}

private final class MeetingHTTPFixture: URLProtocol, @unchecked Sendable {
    // URLProtocol owns the request and its callback queue. This fixture has no mutable state.
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        do {
            if request.httpMethod == "DELETE" {
                guard request.value(forHTTPHeaderField: "MCP-Session-Id") == "fixture-session" else {
                    throw URLError(.badServerResponse)
                }
                finish(status: 405, data: Data(), headers: [:])
                return
            }
            let data = try body()
            let command = try JSONDecoder().decode(Command.self, from: data)
            switch command.method {
            case "initialize":
                try respond(command, result: [
                    "protocolVersion": "2025-06-18",
                    "capabilities": ["tools": [:]],
                    "serverInfo": ["name": "Fixture", "version": "1.0"],
                ], headers: ["Content-Type": "application/json", "MCP-Session-Id": "fixture-session"])
            case "notifications/initialized", "tools/list":
                guard request.value(forHTTPHeaderField: "MCP-Session-Id") == "fixture-session",
                      request.value(forHTTPHeaderField: "MCP-Protocol-Version") == "2025-06-18" else {
                    throw URLError(.badServerResponse)
                }
                if command.method == "notifications/initialized" {
                    finish(status: 202, data: Data(), headers: [:])
                } else {
                    try respond(command, result: [
                        "tools": [["name": "list_meetings", "inputSchema": ["type": "object"]]],
                    ], headers: ["Content-Type": "text/event-stream"])
                }
            default:
                throw URLError(.badServerResponse)
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    private struct Command: Decodable { let id: String?; let method: String }

    private func body() throws -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { throw URLError(.badServerResponse) }
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 2048)
        var data = Data()
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    private func respond(_ command: Command, result: [String: Any], headers: [String: String]) throws {
        guard let id = command.id else { throw URLError(.badServerResponse) }
        var data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])
        if headers["Content-Type"] == "text/event-stream" {
            data = Data("event: message\ndata: ".utf8) + data + Data("\n\n".utf8)
        }
        finish(status: 200, data: data, headers: headers)
    }

    private func finish(status: Int, data: Data, headers: [String: String]) {
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status,
                                                                   httpVersion: nil, headerFields: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }
}
