import Foundation

/// The one serial queue every Accessibility IPC call runs on (capture reads and the rewrite key's
/// focused-field access alike), never the main thread or the Swift cooperative pool. Each call is
/// bounded by `axMessagingTimeout`.
public enum AXQueue {
    static let queue = DispatchQueue(label: "dev.remora.ax", qos: .utility)
    private static let key = DispatchSpecificKey<Bool>()
    private static let marked: Void = queue.setSpecific(key: key, value: true)

    private static var isCurrent: Bool {
        _ = marked
        return DispatchQueue.getSpecific(key: key) == true
    }

    /// Runs `work` on the AX queue with a fresh session and returns its result. Cancelling the
    /// calling task flags the session, which short-circuits all remaining AX calls.
    public static func run<T: Sendable>(
        qos: DispatchQoS = .utility,
        _ work: @escaping @Sendable (AXReadSession) throws -> T
    ) async throws -> T {
        _ = marked
        let session = AXReadSession()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async(qos: qos) {
                    continuation.resume(with: Result { try work(session) })
                }
            }
        } onCancel: {
            session.cancel()
        }
    }

    /// Runs `work` on the AX queue synchronously with a fresh session (inline when already on it).
    /// Blocks the caller for at most a few messaging timeouts; never call it from the main thread.
    public static func sync<T>(_ work: (AXReadSession) -> T) -> T {
        if isCurrent { return work(AXReadSession()) }
        return queue.sync(execute: { work(AXReadSession()) })
    }
}
