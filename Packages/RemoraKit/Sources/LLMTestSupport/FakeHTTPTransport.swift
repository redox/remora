import Foundation
import LLM
import Synchronization

/// A scripted HTTP response.
public struct FakeHTTPResponse: Sendable {
    public var status: Int
    public var body: Data
    public var headers: [String: String]

    public init(status: Int = 200, body: Data = Data(), headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.headers = headers
    }

    /// A JSON body (`object` is anything `JSONSerialization` accepts).
    public static func json(_ status: Int = 200, _ object: Any, headers: [String: String] = [:]) -> FakeHTTPResponse {
        var h = headers
        h["Content-Type"] = h["Content-Type"] ?? "application/json"
        return FakeHTTPResponse(status: status, body: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), headers: h)
    }

    public static func text(_ status: Int = 200, _ text: String, headers: [String: String] = [:]) -> FakeHTTPResponse {
        FakeHTTPResponse(status: status, body: Data(text.utf8), headers: headers)
    }
}

/// An `HTTPTransport` that answers from scripts keyed by URL path and records every request.
/// For each path, queued one-shot responses are used first (FIFO), then the path's handler, if any.
/// An unscripted request throws `URLError(.cannotConnectToHost)`. Never touches the network.
public final class FakeHTTPTransport: HTTPTransport {
    public typealias Handler = @Sendable (URLRequest) async throws -> FakeHTTPResponse

    private struct State {
        var queued: [String: [Handler]] = [:]
        var handlers: [String: Handler] = [:]
        var requests: [URLRequest] = []
    }

    private let state = Mutex(State())

    public init() {}

    /// Answers the next request to `path` once.
    public func enqueue(_ path: String, _ response: FakeHTTPResponse) {
        state.withLock { $0.queued[path, default: []].append { _ in response } }
    }

    /// Fails the next request to `path` once (a transport error).
    public func enqueue(_ path: String, error: any Error & Sendable) {
        state.withLock { $0.queued[path, default: []].append { _ in throw error } }
    }

    /// Answers every request to `path` that has no queued response.
    public func handle(_ path: String, _ handler: @escaping Handler) {
        state.withLock { $0.handlers[path] = handler }
    }

    /// Every request, in arrival order.
    public var requests: [URLRequest] { state.withLock { $0.requests } }

    public func requests(to path: String) -> [URLRequest] {
        requests.filter { $0.url?.path == path }
    }

    private func respond(_ r: URLRequest) async throws -> (FakeHTTPResponse, HTTPURLResponse) {
        let path = r.url?.path ?? ""
        let handler: Handler? = state.withLock { s in
            s.requests.append(r)
            if var q = s.queued[path], !q.isEmpty {
                let next = q.removeFirst()
                s.queued[path] = q
                return next
            }
            return s.handlers[path]
        }
        guard let handler else { throw URLError(.cannotConnectToHost) }
        let response = try await handler(r)
        let http = HTTPURLResponse(url: r.url ?? URL(string: "http://fake.invalid")!, statusCode: response.status,
                                   httpVersion: "HTTP/1.1", headerFields: response.headers)!
        return (response, http)
    }

    public func data(for r: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (response, http) = try await respond(r)
        return (response.body, http)
    }

    /// The body split on `\n`, like `URLSessionTransport` (empty lines kept, no final empty line).
    public func lines(for r: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, any Error>) {
        let (response, http) = try await respond(r)
        var lines = String(decoding: response.body, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        let stream = AsyncThrowingStream<String, any Error> { c in
            for line in lines { c.yield(line) }
            c.finish()
        }
        return (http, stream)
    }
}

extension URLRequest {
    /// The `application/x-www-form-urlencoded` body as a dictionary (last value wins).
    public var formBody: [String: String] {
        guard let body = httpBody, let text = String(data: body, encoding: .utf8), !text.isEmpty else { return [:] }
        var out: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func decode(_ s: Substring) -> String {
                s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(s)
            }
            out[decode(kv[0])] = kv.count > 1 ? decode(kv[1]) : ""
        }
        return out
    }
}
