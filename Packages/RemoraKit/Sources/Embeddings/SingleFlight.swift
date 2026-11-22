/// The in-flight request of a single-flight operation (e.g. one model-asset download shared by
/// concurrent callers). Each `start` gets a token; `finish(token)` clears the slot only when that
/// token's request is still the current one, so a late waiter of an old request never clears a
/// newer one (final review #14). Not thread-safe: keep it inside an actor.
public struct SingleFlight<Request> {
    public private(set) var current: Request?
    private var token = 0
    private var currentToken = 0

    public init() {}

    /// The request in flight with its token, or `make()`'s new one.
    public mutating func join(_ make: () -> Request) -> (request: Request, token: Int) {
        if let current { return (current, currentToken) }
        token += 1
        currentToken = token
        let request = make()
        current = request
        return (request, token)
    }

    /// Clears the slot if `token` is still the current request's.
    public mutating func finish(_ token: Int) {
        if token == currentToken { current = nil }
    }
}
