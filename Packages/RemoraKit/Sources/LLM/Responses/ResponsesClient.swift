import Foundation
import os

extension LLMError {
    /// Maps anything thrown on the way to the network (or by a token fetch) to an `LLMError`.
    static func wrapping(_ error: any Error) -> LLMError {
        if let e = error as? LLMError { return e }
        if error is CancellationError || Task.isCancelled { return .cancelled }
        if let u = error as? URLError { return u.code == .cancelled ? .cancelled : .transport(code: u.code.rawValue) }
        return .transport(code: (error as NSError).code)
    }
}

/// Streams `POST /v1/responses`. Knows nothing about tokens: the caller passes the bearer.
///
/// Logs the HTTP status, a server error code (≤ 64 chars) and `x-request-id`; never request or
/// response text.
public struct ResponsesClient: Sendable {
    private let http: any HTTPTransport
    private let baseURL: URL

    private static let log = Logger(subsystem: "dev.remora", category: "responses")

    public init(http: any HTTPTransport, baseURL: URL = URL(string: SIWC.apiBase)!) {
        self.http = http
        self.baseURL = baseURL
    }

    /// Errors are `LLMError`. Cancelling the consumer cancels the request and closes the transport
    /// stream (the consumer's loop simply ends; a cancellation seen by the producer is `.cancelled`).
    public func stream(_ r: LLMRequest, bearer: String) -> AsyncThrowingStream<LLMEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(r, bearer: bearer, continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: LLMError.wrapping(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ r: LLMRequest, bearer: String, _ out: AsyncThrowingStream<LLMEvent, any Error>.Continuation) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("responses"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try ResponsesRequestEncoder.body(r)

        let (response, lines) = try await http.lines(for: request)
        let requestID = String((response.value(forHTTPHeaderField: "x-request-id") ?? "-").prefix(64))

        guard response.statusCode == 200 else {
            var body = Data()
            for try await line in lines { body.append(contentsOf: line.utf8); body.append(UInt8(ascii: "\n")) }
            let error = ErrorClassifier.classify(status: response.statusCode, body: body)
            Self.log.error("responses: HTTP \(response.statusCode, privacy: .public) \(error.errorCode ?? "-", privacy: .public) request-id \(requestID, privacy: .public)")
            throw error
        }

        var parser = SSEParser()
        for try await line in lines {
            let messages = parser.feed(line: line)
            if parser.overflowed { throw Self.overflow(requestID) }
            if try handle(messages, requestID, out) { return }
        }
        if try handle(parser.finish(), requestID, out) { return }
        if parser.overflowed { throw Self.overflow(requestID) }
        try Task.checkCancellation()
        Self.log.error("responses: stream ended early, request-id \(requestID, privacy: .public)")
        throw LLMError.streamEndedEarly
    }

    private static func overflow(_ requestID: String) -> LLMError {
        log.error("responses: event too large, request-id \(requestID, privacy: .public)")
        return .badRequest(code: "event_too_large", param: nil)
    }

    /// Returns true once the response completed.
    private func handle(_ messages: [SSEMessage], _ requestID: String,
                        _ out: AsyncThrowingStream<LLMEvent, any Error>.Continuation) throws -> Bool {
        for m in messages {
            guard let event = ResponsesEvent.decode(m.data) else { continue }
            switch event {
            case .textDelta(let t):
                if !t.isEmpty { out.yield(.textDelta(t)) }
            case .outputItemDone(let call):
                if let call { out.yield(.functionCall(call)) }
            case .completed(let usage):
                out.yield(.completed(usage))
                return true
            case .failed(let code):
                throw failure(ErrorClassifier.classify(code: code, param: nil), requestID)
            case .error(let code):
                throw failure(ErrorClassifier.classify(code: code, param: nil), requestID)
            case .incomplete(let reason):
                throw failure(.incomplete(reason: reason.map(ErrorClassifier.truncated)), requestID)
            case .other:
                break
            }
        }
        return false
    }

    private func failure(_ e: LLMError, _ requestID: String) -> LLMError {
        Self.log.error("responses: failed \(e.errorCode ?? "-", privacy: .public) request-id \(requestID, privacy: .public)")
        return e
    }
}
