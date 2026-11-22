import Foundation
import LLM
import Synchronization

/// Scripted client for tests. Each `stream` call plays the next script; an exhausted list ends the
/// stream with `.streamEndedEarly`. With `respond`, the script is computed from each request
/// instead. Never touches the network.
public final class FakeLLMClient: LLMClient {
    public enum Step: Sendable {
        case delta(String)
        case functionCall(FunctionCall)
        case complete(LLMUsage)
        case fail(LLMError)
        /// Waits until the consumer cancels.
        case hang
    }

    public let backend: LLMBackend
    private struct State { var scripts: [[Step]]; var seen: [LLMRequest] = [] }
    private let state: Mutex<State>
    private let respond: (@Sendable (LLMRequest) -> [Step])?

    public init(backend: LLMBackend = .siwc, script: [Step]) {
        self.backend = backend
        state = Mutex(State(scripts: [script]))
        respond = nil
    }

    /// One script per call, in order.
    public init(backend: LLMBackend = .siwc, scripts: [[Step]]) {
        self.backend = backend
        state = Mutex(State(scripts: scripts))
        respond = nil
    }

    /// Each call plays `respond(request)`.
    public init(backend: LLMBackend = .siwc, respond: @escaping @Sendable (LLMRequest) -> [Step]) {
        self.backend = backend
        state = Mutex(State(scripts: []))
        self.respond = respond
    }

    /// Answers a `.jsonSchema(name:…)` request with `outputs[name]` as one delta, then `.complete(usage)`;
    /// an unknown name (or a non-schema request) fails with `.badRequest(code: "fake")`.
    public static func bySchema(_ outputs: [String: String],
                                usage: LLMUsage = .init(inputTokens: 1000, cachedInputTokens: 0, outputTokens: 100,
                                                        reasoningTokens: 0)) -> FakeLLMClient {
        FakeLLMClient(backend: .siwc) { request in
            guard case .jsonSchema(let name, _, _) = request.format, let text = outputs[name] else {
                return [.fail(.badRequest(code: "fake", param: nil))]
            }
            return [.delta(text), .complete(usage)]
        }
    }

    public var requests: [LLMRequest] { state.withLock { $0.seen } }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, any Error> {
        let script: [Step]? = state.withLock { s in
            s.seen.append(request)
            if respond != nil { return nil }
            return s.scripts.isEmpty ? nil : s.scripts.removeFirst()
        } ?? respond?(request)
        return AsyncThrowingStream { c in
            let task = Task {
                guard let script else { c.finish(throwing: LLMError.streamEndedEarly); return }
                for step in script {
                    switch step {
                    case .delta(let t): c.yield(.textDelta(t))
                    case .functionCall(let f): c.yield(.functionCall(f))
                    case .complete(let u): c.yield(.completed(u)); c.finish(); return
                    case .fail(let e): c.finish(throwing: e); return
                    case .hang:
                        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
                        c.finish()
                        return
                    }
                }
                c.finish(throwing: LLMError.streamEndedEarly)
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
}
