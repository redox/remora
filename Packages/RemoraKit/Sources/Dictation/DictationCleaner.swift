import Foundation
import LLM
import Rewrite
import os

public struct CleanupOutcome: Sendable, Equatable {
    public var text: String
    public var cleaned: Bool
    public var notice: DictationNotice?
    public init(text: String, cleaned: Bool, notice: DictationNotice?) {
        self.text = text; self.cleaned = cleaned; self.notice = notice
    }
}

/// Cleans a transcript through `LLMService` (job `dictation_cleanup`) and falls back to the raw
/// transcript on any failure, timeout or rejected answer. Never logs text.
public actor DictationCleaner {
    public static let minWords = 4
    private static let log = Logger(subsystem: "dev.remora", category: "dictation")

    private let llm: LLMService
    private let timeout: Duration

    public init(llm: LLMService, timeout: Duration = .seconds(8)) {
        self.llm = llm; self.timeout = timeout
    }

    private enum Race: Sendable { case done(LLMResult), failed(any Error), timedOut }

    /// Throws only `CancellationError`.
    public func process(raw: String, locale: DictationLocale?, cleanupEnabled: Bool,
                        cloudAllowed: Bool) async throws -> CleanupOutcome {
        let words = raw.split(whereSeparator: \.isWhitespace).count
        guard cleanupEnabled, words >= Self.minWords else { return .init(text: raw, cleaned: false, notice: nil) }
        let prompt = DictationPrompt.make(transcript: raw, locale: locale)
        let llm = self.llm, timeout = self.timeout
        let race = await withTaskGroup(of: Race.self) { group in
            group.addTask {
                do {
                    return .done(try await llm.complete(.dictationCleanup, instructions: prompt.instructions,
                                                        input: prompt.input, cloudAllowed: cloudAllowed))
                } catch { return .failed(error) }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
        if Task.isCancelled { throw CancellationError() }
        let skipped = CleanupOutcome(text: raw, cleaned: false, notice: .cleanupSkipped)
        switch race {
        case .done(let result):
            guard CleanupGuard.accept(raw: raw, cleaned: result.text) else {
                Self.log.info("cleanup rejected by guard")
                return skipped
            }
            let text = OutputCleaner.clean(result.text, original: raw)
            guard !text.isEmpty else { return skipped }
            return .init(text: text, cleaned: true, notice: nil)
        case .failed:
            Self.log.info("cleanup failed; inserting raw")
            return skipped
        case .timedOut:
            Self.log.info("cleanup timed out; inserting raw")
            return skipped
        }
    }
}
