import Foundation
import Logging
import MCP

/// Uses the SDK client for MCP messages and a private session for Streamable HTTP.
/// Refusing redirects ensures a loopback server cannot relay requests to an external host.
actor MeetingHTTPTransport: Transport {
    private struct Envelope: Decodable {
        let jsonrpc: String
        let id: ID?
        let method: String?
        let result: Value?
        let error: MCPError?
    }

    private let endpoint: URL
    private let token: String?
    private let session: URLSession
    private let makeCleanupSession: @Sendable () -> URLSession
    private var sessionID: String?
    private var protocolVersion: String?
    private var connected = false
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    nonisolated let logger = Logger(label: "dev.remora.meeting-mcp") { _ in SwiftLogNoOpLogHandler() }

    init(endpoint: URL, token: String?, session: URLSession = MeetingHTTPSession.make(),
         makeCleanupSession: @escaping @Sendable () -> URLSession = { MeetingHTTPSession.make(timeout: 2) }) {
        self.endpoint = endpoint
        self.token = token
        self.session = session
        self.makeCleanupSession = makeCleanupSession
        (stream, continuation) = AsyncThrowingStream.makeStream()
    }

    func connect() { connected = true }

    func disconnect() async {
        guard connected else { return }
        connected = false
        continuation.finish()
        var end = makeRequest(method: "DELETE")
        end.timeoutInterval = 2
        session.invalidateAndCancel()
        guard sessionID != nil else { return }
        let cleanup = makeCleanupSession()
        defer { cleanup.invalidateAndCancel() }
        _ = try? await cleanup.data(for: end)
    }

    func receive() -> AsyncThrowingStream<Data, Error> { stream }

    func send(_ data: Data) async throws {
        guard connected else { throw CancellationError() }
        // Incoming server requests are never forwarded to the client, so all outbound
        // messages are the SDK's initialize, list/call, or notifications.
        let command = try JSONDecoder().decode(Envelope.self, from: data)
        var request = makeRequest(method: "POST")
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // The SDK waits for a reply by request ID. Bound the read even when the server
        // sends an endless stream of comments that would keep the socket busy.
        let (bytes, rawResponse) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = rawResponse as? HTTPURLResponse else { throw MeetingImportError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw MeetingImportError.httpStatus(response.statusCode) }
        guard connected else { throw CancellationError() }
        if let id = response.value(forHTTPHeaderField: "MCP-Session-Id") { sessionID = id }
        guard let requestID = command.id else { return }

        let message: Data
        switch response.mimeType {
        case "text/event-stream":
            message = try await Self.eventReply(bytes, id: requestID)
        case "application/json":
            message = try await Self.jsonReply(bytes)
        default:
            throw MeetingImportError.invalidResponse
        }
        let reply = try JSONDecoder().decode(Envelope.self, from: message)
        guard reply.jsonrpc == "2.0", reply.id == requestID, reply.method == nil,
              (reply.result != nil) != (reply.error != nil) else { throw MeetingImportError.invalidResponse }
        if command.method == "initialize" { protocolVersion = reply.result?.objectValue?["protocolVersion"]?.stringValue }
        continuation.yield(message)
    }

    private func makeRequest(method: String) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id")
        request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private static let maximumBytes = 8 * 1024 * 1024

    private static func jsonReply(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw MeetingImportError.responseTooLarge }
            data.append(byte)
        }
        return data
    }

    private static func eventReply(_ bytes: URLSession.AsyncBytes, id: ID) async throws -> Data {
        var line = Data()
        var event = Data()
        var received = 0
        for try await byte in bytes {
            received += 1
            guard received <= maximumBytes else { throw MeetingImportError.responseTooLarge }
            guard byte == 10 else { line.append(byte); continue }
            if line.last == 13 { line.removeLast() }
            if line.isEmpty {
                if let envelope = try? JSONDecoder().decode(Envelope.self, from: event),
                   envelope.id == id, envelope.method == nil { return event }
                event.removeAll(keepingCapacity: true)
            } else if line.starts(with: "data:".utf8) {
                let value = line.dropFirst(5)
                if !event.isEmpty { event.append(10) }
                event.append(contentsOf: value.first == 32 ? value.dropFirst() : value)
            }
            line.removeAll(keepingCapacity: true)
        }
        throw MeetingImportError.invalidResponse
    }
}

enum MeetingHTTPSession {
    static func make(timeout: TimeInterval = 35) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = timeout
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
