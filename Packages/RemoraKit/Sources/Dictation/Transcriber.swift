import AVFoundation
import Foundation
import Speech

public struct TranscriberResult: Sendable, Equatable {
    public var text: String
    public var isFinal: Bool

    public var startSeconds: TimeInterval?
    public var endSeconds: TimeInterval?

    public init(text: String, isFinal: Bool, startSeconds: TimeInterval? = nil, endSeconds: TimeInterval? = nil) {
        self.text = text
        self.isFinal = isFinal
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}

/// On-device speech-to-text for one locale per transcription.
public protocol Transcriber: Sendable {
    /// The audio format the analyzer wants for `l`.
    func format(for l: DictationLocale) async throws -> AVAudioFormat
    /// Loads the model for `l` ahead of a session.
    func prewarm(_ l: DictationLocale) async
    /// Transcribes `input`. The result stream finishes after `input` ends and the analyzer has finalized;
    /// cancelling the consumer cancels the analysis.
    func transcribe(_ l: DictationLocale, format: AVAudioFormat,
                    input: AsyncStream<AnalyzerInput>) -> AsyncThrowingStream<TranscriberResult, any Error>
}

public struct TranscriptUpdate: Sendable, Equatable {
    public var finalized: String
    public var volatile: String

    public init(finalized: String = "", volatile: String = "") {
        self.finalized = finalized
        self.volatile = volatile
    }

    /// Finalized text plus the volatile tail, trimmed.
    public var text: String {
        TranscriptAccumulator.join(finalized, volatile).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Folds transcriber results into finalized text plus a volatile tail.
public struct TranscriptAccumulator: Sendable {
    public private(set) var current = TranscriptUpdate()

    public init() {}

    /// A final result is appended to `finalized` and clears `volatile`; a volatile one replaces `volatile`.
    public mutating func apply(_ r: TranscriberResult) -> TranscriptUpdate {
        let segment = Self.trimmingTrailingWhitespace(r.text)
        if r.isFinal {
            current.finalized = Self.join(current.finalized, segment)
            current.volatile = ""
        } else {
            current.volatile = segment
        }
        return current
    }

    /// Appends as is when `segment` starts with whitespace or `base` is empty or ends with whitespace;
    /// otherwise inserts one space.
    static func join(_ base: String, _ segment: String) -> String {
        guard let first = segment.first else { return base }
        guard let last = base.last, !first.isWhitespace, !last.isWhitespace else { return base + segment }
        return base + " " + segment
    }

    static func trimmingTrailingWhitespace(_ s: String) -> String {
        var s = Substring(s)
        while let last = s.last, last.isWhitespace { s.removeLast() }
        return String(s)
    }
}
