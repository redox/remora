import Foundation
import LLMTestSupport
import Synchronization
import Testing
@testable import LLM

// SSE fixtures (the event shapes observed by the spike).
func sseEvent(_ type: String, _ extra: String = "") -> String {
    "event: \(type)\ndata: {\"type\":\"\(type)\"\(extra)}\n\n"
}

func sseDelta(_ text: String) -> String { sseEvent("response.output_text.delta", #","delta":"\#(text)""#) }

let sseCompleted = sseEvent("response.completed",
    #","response":{"usage":{"input_tokens":21,"input_tokens_details":{"cached_tokens":4},"output_tokens":6,"output_tokens_details":{"reasoning_tokens":2}}}"#)

let fixtureUsage = LLMUsage(inputTokens: 21, cachedInputTokens: 4, outputTokens: 6, reasoningTokens: 2)

func sseStream(_ parts: String...) -> String {
    sseEvent("response.created") + sseEvent("response.in_progress") + parts.joined()
}

let responsesPath = "/v1/responses"

func sampleRequest() -> LLMRequest {
    LLMRequest(model: "gpt-6-luna", instructions: "Reply in French.", input: [.user("Say hello")], reasoning: .low)
}

/// Collects a stream: the events before it ended, and the error (if any).
func collect(_ stream: AsyncThrowingStream<LLMEvent, any Error>) async -> (events: [LLMEvent], error: LLMError?) {
    var events: [LLMEvent] = []
    do {
        for try await e in stream { events.append(e) }
        return (events, nil)
    } catch let e as LLMError {
        return (events, e)
    } catch {
        return (events, .http(status: -1))
    }
}

private func client(_ fake: FakeHTTPTransport) -> ResponsesClient { ResponsesClient(http: fake) }

@Test func streamsDeltasThenCompleted() async throws {
    let fake = FakeHTTPTransport()
    fake.enqueue(responsesPath, .text(200, sseStream(sseDelta("Bon"), sseDelta("jour !"), sseCompleted)))
    let r = await collect(client(fake).stream(sampleRequest(), bearer: "at-1"))
    #expect(r.events == [.textDelta("Bon"), .textDelta("jour !"), .completed(fixtureUsage)])
    #expect(r.error == nil)
}

@Test func preStreamDetailErrorClassified() async {
    let fake = FakeHTTPTransport()
    fake.enqueue(responsesPath, .json(401, ["detail": "Unauthorized"]))
    let r = await collect(client(fake).stream(sampleRequest(), bearer: "at-1"))
    #expect(r.events.isEmpty && r.error == .unauthorized)
}

@Test func preStreamErrorObjectClassified() async {
    let fake = FakeHTTPTransport()
    fake.enqueue(responsesPath, .json(429, ["error": ["code": "subscription_sharing_usage_limit_exceeded"]]))
    #expect(await collect(client(fake).stream(sampleRequest(), bearer: "at-1")).error == .usageLimit)
}

@Test func midStreamFailureThrowsAfterDeltas() async {
    let fake = FakeHTTPTransport()
    let failed = sseEvent("response.failed", #","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"do not log me"}}"#)
    fake.enqueue(responsesPath, .text(200, sseStream(sseDelta("Bon"), failed)))
    let r = await collect(client(fake).stream(sampleRequest(), bearer: "at-1"))
    #expect(r.events == [.textDelta("Bon")])
    #expect(r.error == .usageLimit)
}

@Test func unknownMidStreamErrorCodeIsRetryableAndTruncated() async {
    let fake = FakeHTTPTransport()
    fake.enqueue(responsesPath, .text(200, sseStream(sseEvent("response.failed", #","response":{"error":{"code":"server_error"}}"#))))
    let a = await collect(client(fake).stream(sampleRequest(), bearer: "t"))
    #expect(a.error == .temporarilyUnavailable(code: "server_error") && a.error?.isRetryable == true)

    let long = String(repeating: "z", count: 300)
    fake.enqueue(responsesPath, .text(200, sseStream(sseEvent("error", #","code":"\#(long)""#))))
    let b = await collect(client(fake).stream(sampleRequest(), bearer: "t"))
    #expect(b.error == .temporarilyUnavailable(code: String(repeating: "z", count: 64)))
}

@Test func errorEventUsesTheClassifier() async {
    let fake = FakeHTTPTransport()
    fake.enqueue(responsesPath, .text(200, sseStream(sseEvent("error", #","code":"subscription_sharing_user_not_eligible""#))))
    #expect(await collect(client(fake).stream(sampleRequest(), bearer: "t")).error == .notEligible)
}

@Test func incompleteThrowsIncomplete() async {
    let fake = FakeHTTPTransport()
    fake.enqueue(responsesPath, .text(200, sseStream(sseDelta("x"),
        sseEvent("response.incomplete", #","response":{"incomplete_details":{"reason":"content_filter"}}"#))))
    let r = await collect(client(fake).stream(sampleRequest(), bearer: "t"))
    #expect(r.events == [.textDelta("x")] && r.error == .incomplete(reason: "content_filter"))
}

@Test func streamWithoutTerminalEventThrows() async {
    let fake = FakeHTTPTransport()
    fake.enqueue(responsesPath, .text(200, sseStream(sseDelta("Bon"))))
    let r = await collect(client(fake).stream(sampleRequest(), bearer: "t"))
    #expect(r.events == [.textDelta("Bon")] && r.error == .streamEndedEarly)
}

@Test func unterminatedFinalEventIsStillDelivered() async {
    let fake = FakeHTTPTransport()
    // No blank line after the last event: the parser's finish() must flush it.
    let tail = String(sseCompleted.dropLast())
    fake.enqueue(responsesPath, .text(200, sseStream(sseDelta("a")) + tail))
    let r = await collect(client(fake).stream(sampleRequest(), bearer: "t"))
    #expect(r.events == [.textDelta("a"), .completed(fixtureUsage)] && r.error == nil)
}

@Test func functionCallKeepsItsNamespace() async {
    let fake = FakeHTTPTransport()
    let item = sseEvent("response.output_item.done",
        #","item":{"type":"function_call","call_id":"call_1","namespace":"remora","name":"get_weather","arguments":"{\"city\":\"Paris\"}"}"#)
    fake.enqueue(responsesPath, .text(200, sseStream(item, sseCompleted)))
    let r = await collect(client(fake).stream(sampleRequest(), bearer: "t"))
    #expect(r.events == [.functionCall(FunctionCall(callID: "call_1", namespace: "remora", name: "get_weather", arguments: #"{"city":"Paris"}"#)),
                         .completed(fixtureUsage)])
}

@Test func oversizedEventEndsTheStreamWithAnError() async {
    let fake = FakeHTTPTransport()
    var body = sseStream(sseDelta("a")) + "data: "
    body += String(repeating: "x", count: 9 * 1_048_576) + "\n\n"
    fake.enqueue(responsesPath, .text(200, body))
    let r = await collect(client(fake).stream(sampleRequest(), bearer: "t"))
    #expect(r.events == [.textDelta("a")] && r.error == .badRequest(code: "event_too_large", param: nil))
}

@Test func requestHeadersAndBody() async throws {
    let fake = FakeHTTPTransport()
    fake.enqueue(responsesPath, .text(200, sseStream(sseCompleted)))
    _ = await collect(client(fake).stream(sampleRequest(), bearer: "at-1"))
    let req = try #require(fake.requests(to: responsesPath).first)
    #expect(req.httpMethod == "POST")
    #expect(req.url?.absoluteString == "https://api.openai.com/v1/responses")
    #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer at-1")
    #expect(req.value(forHTTPHeaderField: "Accept") == "text/event-stream")
    #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let raw = try #require(req.httpBody)
    let body = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
    #expect(body["store"] as? Bool == false && body["stream"] as? Bool == true)
    #expect(body["model"] as? String == "gpt-6-luna" && body["instructions"] as? String == "Reply in French.")
}

@Test func transportErrorsMapToLLMErrors() async {
    let fake = FakeHTTPTransport()
    fake.enqueue(responsesPath, error: URLError(.timedOut))
    #expect(await collect(client(fake).stream(sampleRequest(), bearer: "t")).error == .transport(code: URLError.timedOut.rawValue))
    fake.enqueue(responsesPath, error: URLError(.cancelled))
    #expect(await collect(client(fake).stream(sampleRequest(), bearer: "t")).error == .cancelled)
}

/// A transport whose body yields one delta and then never ends; records when the line stream is torn down.
private final class HangingTransport: HTTPTransport {
    private let terminated = Mutex(false)
    private let keepAlive = Mutex<AsyncThrowingStream<String, any Error>.Continuation?>(nil)
    var isTerminated: Bool { terminated.withLock { $0 } }

    func data(for r: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.cannotConnectToHost) }

    func lines(for r: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, any Error>) {
        let http = HTTPURLResponse(url: r.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        let stream = AsyncThrowingStream<String, any Error> { c in
            for line in sseDelta("Bon").split(separator: "\n", omittingEmptySubsequences: false) { c.yield(String(line)) }
            c.onTermination = { _ in self.terminated.withLock { $0 = true } }
            self.keepAlive.withLock { $0 = c }
        }
        return (http, stream)
    }
}

@Test func cancellationStopsStreamAndTransport() async throws {
    let transport = HangingTransport()
    let stream = ResponsesClient(http: transport).stream(sampleRequest(), bearer: "t")
    let seen = Mutex(0)
    let consumer = Task {
        var out: [LLMEvent] = []
        do { for try await e in stream { out.append(e); seen.withLock { $0 += 1 } } } catch {}
        return out
    }
    for _ in 0..<200 where seen.withLock({ $0 }) == 0 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(seen.withLock { $0 } == 1)
    consumer.cancel()
    #expect(await consumer.value == [.textDelta("Bon")])
    for _ in 0..<200 where !transport.isTerminated { try await Task.sleep(for: .milliseconds(10)) }
    #expect(transport.isTerminated)
}
