import Foundation
import FoundationModels

public enum OnDeviceAvailability: Sendable, Equatable {
    case available
    case unavailable(String)
}

/// The Apple on-device model, behind a protocol so tests never touch the system model.
public protocol OnDeviceModel: Sendable {
    var availability: OnDeviceAvailability { get }
    /// Cumulative snapshots: each element is the whole text so far.
    func respond(instructions: String, prompt: String) -> AsyncThrowingStream<String, any Error>
}

/// `SystemLanguageModel.default` + `LanguageModelSession`. Not instantiated by unit tests.
public struct SystemOnDeviceModel: OnDeviceModel {
    public init() {}

    public var availability: OnDeviceAvailability {
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(.deviceNotEligible): return .unavailable("This Mac is not eligible for Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled): return .unavailable("Apple Intelligence is turned off.")
        case .unavailable(.modelNotReady): return .unavailable("The on-device model is not ready yet.")
        case .unavailable: return .unavailable("The on-device model is unavailable.")
        }
    }

    public func respond(instructions: String, prompt: String) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session = LanguageModelSession(instructions: instructions)
                    for try await snapshot in session.streamResponse(to: prompt) {
                        continuation.yield(snapshot.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
