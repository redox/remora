import Foundation

/// Responses calls authenticated with the signed-in ChatGPT session.
///
/// A 401 before the first event forces one token refresh (for the token that was rejected) and
/// retries once. A second 401, or a 401 after events were already delivered, surfaces as is.
public struct SIWCClient: LLMClient {
    public let backend: LLMBackend = .siwc
    private let tokens: TokenManager
    private let responses: ResponsesClient

    public init(tokens: TokenManager, responses: ResponsesClient) {
        self.tokens = tokens
        self.responses = responses
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var token = try await tokens.accessToken()
                    var retried = false
                    while true {
                        var delivered = false
                        do {
                            for try await event in responses.stream(request, bearer: token) {
                                delivered = true
                                continuation.yield(event)
                            }
                            continuation.finish()
                            return
                        } catch LLMError.unauthorized where !delivered && !retried {
                            retried = true
                            token = try await tokens.forceRefresh(rejected: token)
                        }
                    }
                } catch {
                    continuation.finish(throwing: LLMError.wrapping(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
