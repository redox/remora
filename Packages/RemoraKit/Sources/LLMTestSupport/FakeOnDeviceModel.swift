import Foundation
import LLM
import Synchronization

/// Scripts the on-device side: cumulative snapshots, or a thrown error after them.
public final class FakeOnDeviceModel: OnDeviceModel {
    public let availability: OnDeviceAvailability
    private let snapshots: [String]
    private let error: (any Error & Sendable)?
    private let seen = Mutex<[(instructions: String, prompt: String)]>([])

    public init(availability: OnDeviceAvailability = .available, snapshots: [String] = [],
                error: (any Error & Sendable)? = nil) {
        self.availability = availability; self.snapshots = snapshots; self.error = error
    }

    /// Every `respond` call.
    public var calls: [(instructions: String, prompt: String)] { seen.withLock { $0 } }

    public func respond(instructions: String, prompt: String) -> AsyncThrowingStream<String, any Error> {
        seen.withLock { $0.append((instructions, prompt)) }
        let snapshots = snapshots, error = error
        return AsyncThrowingStream { c in
            for s in snapshots { c.yield(s) }
            c.finish(throwing: error)
        }
    }
}
