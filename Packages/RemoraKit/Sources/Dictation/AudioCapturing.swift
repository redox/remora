import AVFoundation
import Speech

public enum DictationError: Error, Sendable, Equatable {
    case noInputDevice, audio(String), noCompatibleFormat, transcriber(String), alreadyRunning
    case tooManyReservedLanguages
}

extension DictationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .tooManyReservedLanguages: "Too many speech languages reserved. Remove one in System Settings and try again."
        default: nil
        }
    }
}

public enum AudioEvent: Sendable {
    /// Audio already converted to the analyzer's format. Lives in memory only.
    case chunk(AnalyzerInput)
    /// Input level, 0…1, at most ~20 Hz.
    case level(Float)
    /// The input device or engine configuration changed under the session (sleep, unplugged, AirPods gone).
    case interrupted
}

/// Microphone capture, converted to the transcriber's format. Never writes audio anywhere.
public protocol AudioCapturing: Sendable {
    /// Starts capture. Throws `DictationError.noInputDevice` or `.audio(_)`.
    func start(format: AVAudioFormat) async throws -> AsyncStream<AudioEvent>
    /// Stops capture and ends the stream. Idempotent.
    func stop() async
}
