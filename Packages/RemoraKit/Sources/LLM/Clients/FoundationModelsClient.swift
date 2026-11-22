import Foundation

public enum TokenEstimate {
    /// ceil(UTF-8 bytes / 3): a deliberately rough, slightly high estimate.
    public static func count(_ text: String) -> Int { (text.utf8.count + 2) / 3 }
}

/// The on-device backend. It estimates tokens (the system model reports none) and refuses, before
/// generating anything, when the model is unavailable or the input is too large for its small context.
public struct FoundationModelsClient: LLMClient {
    public let backend: LLMBackend = .onDevice
    public static let modelID = "apple.foundation-models"
    public static let maxInputTokens = 3_000
    static let schemaInstruction = "Respond with only a JSON object matching this JSON Schema:"

    private let model: any OnDeviceModel

    public init(model: any OnDeviceModel) { self.model = model }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(request, continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ r: LLMRequest, _ out: AsyncThrowingStream<LLMEvent, any Error>.Continuation) async throws {
        guard r.tools.isEmpty else { throw LLMError.unsupported(param: "tools") }
        if case .unavailable(let reason) = model.availability { throw LLMError.onDeviceUnavailable(reason: reason) }
        let instructions = Self.instructions(r)
        let prompt = try Self.flatten(r.input)
        let inputTokens = TokenEstimate.count(instructions) + TokenEstimate.count(prompt)
        guard inputTokens <= Self.maxInputTokens else {
            throw LLMError.onDeviceUnavailable(reason: "The input is too large for the on-device model.")
        }
        var emitted = ""
        for try await snapshot in model.respond(instructions: instructions, prompt: prompt) {
            if snapshot.utf8.starts(with: emitted.utf8) {
                let tail = snapshot.utf8.dropFirst(emitted.utf8.count)
                if !tail.isEmpty {
                    out.yield(.textDelta(String(decoding: Array(tail), as: UTF8.self)))
                    emitted = snapshot
                }
            } else if !emitted.utf8.starts(with: snapshot.utf8) {
                throw LLMError.onDeviceUnavailable(reason: "The on-device model revised its output.")
            }
        }
        try Task.checkCancellation()
        out.yield(.completed(LLMUsage(inputTokens: inputTokens, cachedInputTokens: 0,
                                      outputTokens: TokenEstimate.count(emitted), reasoningTokens: 0)))
    }

    static func instructions(_ r: LLMRequest) -> String {
        guard case .jsonSchema(_, let schema, _) = r.format else { return r.instructions }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let json = (try? enc.encode(schema)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return r.instructions + "\n\n" + schemaInstruction + "\n" + json
    }

    static func flatten(_ input: [InputItem]) throws -> String {
        try input.map { item in
            switch item {
            case .user(let t): return "user: \(t)"
            case .assistant(let t): return "assistant: \(t)"
            case .functionCall, .functionCallOutput: throw LLMError.unsupported(param: "tools")
            }
        }.joined(separator: "\n")
    }

    /// Anything the system model throws other than ours becomes "unavailable", so the router can fall
    /// back to the small tier (the generic reason carries no content).
    private static func map(_ error: any Error) -> LLMError {
        if let e = error as? LLMError { return e }
        if error is CancellationError || Task.isCancelled { return .cancelled }
        return .onDeviceUnavailable(reason: "The on-device model failed.")
    }
}
