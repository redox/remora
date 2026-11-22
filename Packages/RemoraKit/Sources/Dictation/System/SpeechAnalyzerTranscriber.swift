import AVFoundation
import Foundation
import os
import Speech

/// On-device transcription with `SpeechAnalyzer` + `SpeechTranscriber` (one locale per session).
/// Uses only Speech symbols available in macOS 26.
public struct SpeechAnalyzerTranscriber: Transcriber {
    private static let log = Logger(subsystem: "dev.remora", category: "dictation")
    /// How long a prewarmed analyzer waits for its session.
    static let prewarmLifetime: Duration = .seconds(5)

    private let prewarmed = PrewarmCache()

    public init() {}

    public func format(for l: DictationLocale) async throws -> AVAudioFormat {
        let module = Self.makeModule(await Self.resolvedLocale(l))
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw DictationError.noCompatibleFormat
        }
        return format
    }

    public func prewarm(_ l: DictationLocale) async {
        let module = Self.makeModule(await Self.resolvedLocale(l))
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else { return }
        let analyzer = Self.makeAnalyzer(module)
        do {
            try await analyzer.prepareToAnalyze(in: format)
        } catch {
            await analyzer.cancelAndFinishNow()
            Self.log.error("dictation prewarm failed locale=\(l.rawValue, privacy: .public) error=\(String(describing: type(of: error)), privacy: .public)")
            return
        }
        await prewarmed.store(.init(locale: l, format: format, module: module, analyzer: analyzer,
                                    expires: ContinuousClock.now.advanced(by: Self.prewarmLifetime)))
        Self.log.info("dictation prewarmed locale=\(l.rawValue, privacy: .public)")
    }

    public func transcribe(_ l: DictationLocale, format: AVAudioFormat,
                           input: AsyncStream<AnalyzerInput>) -> AsyncThrowingStream<TranscriberResult, any Error> {
        let prewarmed = self.prewarmed
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Self.run(l, format: format, input: input, prewarmed: prewarmed,
                                       continuation: continuation)
                    continuation.finish()
                } catch {
                    if !(error is CancellationError) {
                        Self.log.error("dictation analysis failed locale=\(l.rawValue, privacy: .public) error=\(String(describing: type(of: error)), privacy: .public)")
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Analysis

    private static func run(_ l: DictationLocale, format: AVAudioFormat, input: AsyncStream<AnalyzerInput>,
                            prewarmed: PrewarmCache,
                            continuation: AsyncThrowingStream<TranscriberResult, any Error>.Continuation) async throws {
        let module: SpeechTranscriber
        let analyzer: SpeechAnalyzer
        let needsPreparing: Bool
        if let ready = await prewarmed.take(l, format: format) {
            module = ready.module
            analyzer = ready.analyzer
            needsPreparing = false
        } else {
            module = makeModule(await resolvedLocale(l))
            analyzer = makeAnalyzer(module)
            needsPreparing = true
        }
        do {
            if needsPreparing { try await analyzer.prepareToAnalyze(in: format) }
            try Task.checkCancellation()
            try await analyze(input, module: module, analyzer: analyzer, continuation: continuation)
        } catch {
            // Error or cancellation: release the analyzer before reporting.
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    private static func analyze(_ input: AsyncStream<AnalyzerInput>, module: SpeechTranscriber, analyzer: SpeechAnalyzer,
                                continuation: AsyncThrowingStream<TranscriberResult, any Error>.Continuation) async throws {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for try await r in module.results {
                        continuation.yield(TranscriberResult(text: String(r.text.characters), isFinal: r.isFinal))
                    }
                }
                let last = try await analyzer.analyzeSequence(input)
                try Task.checkCancellation()
                if let last {
                    try await analyzer.finalizeAndFinish(through: last)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
                // The results sequence ends once the analyzer has finished.
                try await group.waitForAll()
            }
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    private static func resolvedLocale(_ l: DictationLocale) async -> Locale {
        await SpeechTranscriber.supportedLocale(equivalentTo: l.locale) ?? l.locale
    }

    static func makeModule(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults],
                          attributeOptions: [])
    }

    private static func makeAnalyzer(_ module: SpeechTranscriber) -> SpeechAnalyzer {
        SpeechAnalyzer(modules: [module], options: .init(priority: .userInitiated, modelRetention: .lingering))
    }
}

/// Holds at most one prepared analyzer, handed to the next session in the same locale and format
/// within `SpeechAnalyzerTranscriber.prewarmLifetime`. A replaced, expired or mismatched analyzer is
/// finished (`cancelAndFinishNow`) so it releases its resources.
actor PrewarmCache {
    struct Prepared: Sendable {
        let locale: DictationLocale
        let format: AVAudioFormat
        let module: SpeechTranscriber
        let analyzer: SpeechAnalyzer
        let expires: ContinuousClock.Instant
    }

    private var prepared: Prepared?
    private var storeGeneration = 0

    func store(_ p: Prepared) {
        if let old = prepared { Self.discard(old) }
        prepared = p
        storeGeneration += 1
        let generation = storeGeneration
        Task { [weak self] in
            try? await Task.sleep(until: p.expires, clock: .continuous)
            await self?.expire(generation)
        }
    }

    /// Nobody took the prewarmed analyzer in time: finish it.
    private func expire(_ generation: Int) {
        guard generation == storeGeneration, let p = prepared else { return }
        prepared = nil
        Self.discard(p)
    }

    func take(_ l: DictationLocale, format: AVAudioFormat) -> Prepared? {
        guard let p = prepared else { return nil }
        prepared = nil
        guard p.locale == l, p.format == format, ContinuousClock.now < p.expires else {
            Self.discard(p)
            return nil
        }
        return p
    }

    private static func discard(_ p: Prepared) {
        let analyzer = p.analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }
}
