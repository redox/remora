import AVFoundation
import Foundation
import os
import Speech

public struct SessionLimits: Sendable, Equatable {
    public var maxDuration: Duration
    public var finalizeTimeout: Duration

    public init(maxDuration: Duration = .seconds(300), finalizeTimeout: Duration = .seconds(2)) {
        self.maxDuration = maxDuration
        self.finalizeTimeout = finalizeTimeout
    }
}

public struct CompletedDictation: Sendable {
    public let text: String
    public let wav: Data?
    public let receivedAudio: Bool
}

/// One dictation session over `AudioCapturing` and `Transcriber`.
///
/// The in-memory chunks (at most `maxDuration` of audio) can be replayed on locale switch or encoded
/// for an eligible transcription request at finish. The session drops them on every exit and calls
/// `audio.stop()` once per `audio.start`, plus once more when stop races an unfinished start.
public actor DictationSession {
    public enum Event: Sendable, Equatable {
        /// A converted microphone buffer has arrived for the current capture.
        case listening(DictationLocale)
        case transcript(TranscriptUpdate)
        case level(Float)
        /// Audio stopped under the session; the text so far is kept. The controller calls `finish`.
        case interrupted
        /// `maxDuration` elapsed; audio is stopped. The controller calls `finish`.
        case limitReached
        /// The session stopped listening; the text so far is kept.
        case failed(DictationError)
    }

    private enum Phase { case idle, running, finishing, ended }

    private static let log = Logger(subsystem: "dev.remora", category: "dictation")

    public nonisolated let events: AsyncStream<Event>
    private let sink: AsyncStream<Event>.Continuation
    private let audio: any AudioCapturing
    private let transcriber: any Transcriber
    private let limits: SessionLimits
    private let waitForLimit: @Sendable (Duration) async throws -> Void

    public private(set) var locale: DictationLocale

    private var phase = Phase.idle
    private var format: AVAudioFormat?

    // Audio: one generation per `audio.start`.
    private var audioRunning = false
    private var audioGeneration = 0
    private var audioTask: Task<Void, Never>?
    private var limitTask: Task<Void, Never>?
    private var limitHit = false

    // Transcription: one generation per `transcriber.transcribe`.
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var transcription: Task<Void, Never>?
    private var transcriptionGeneration = 0
    private var switchGeneration = 0

    /// Chunks heard so far, for replay on a locale switch. Capped by `maxDuration`: nothing is accepted
    /// once the cap is hit, and audio stops then.
    private var buffered: [AnalyzerInput] = []
    private var accumulator = TranscriptAccumulator()

    public init(audio: any AudioCapturing, transcriber: any Transcriber, locale: DictationLocale,
                limits: SessionLimits = .init(),
                waitForLimit: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.audio = audio
        self.transcriber = transcriber
        self.locale = locale
        self.limits = limits
        self.waitForLimit = waitForLimit
        (events, sink) = AsyncStream<Event>.makeStream()
    }

    // MARK: Test probes (no content leaves through these but the text the caller already owns)

    var bufferedChunkCount: Int { buffered.count }
    var currentText: String { accumulator.current.text }
    var isRunning: Bool { phase == .running }

    // MARK: Lifecycle

    public func start() async throws {
        guard phase == .idle else { throw DictationError.alreadyRunning }
        phase = .running
        do {
            let fmt = try await transcriber.format(for: locale)
            guard phase == .running else { return }
            format = fmt
            beginTranscription(replay: [])
            try await startAudio(format: fmt)
        } catch {
            let e = Self.mapped(error) { .transcriber($0) }
            Self.log.error("dictation start failed: \(Self.kind(e), privacy: .public)")
            cancelTranscription()
            await stopAudio()
            end()
            throw e
        }
        guard phase == .running else { return }
        limitTask = Task { [maxDuration = limits.maxDuration, waitForLimit] in
            // Holds the session on purpose: the cap stops the microphone even if nobody calls finish.
            do { try await waitForLimit(maxDuration) } catch { return }
            guard !Task.isCancelled else { return }
            await self.reachLimit()
        }
    }

    /// Stops audio, lets the transcriber finalize for at most `finalizeTimeout`, and returns the
    /// finalized text plus any volatile tail. Drops the buffers and the text.
    public func finish() async -> String {
        await finish(retainAudio: false).text
    }

    /// Encodes audio from this session only when requested by the cloud transcription path.
    public func finish(retainAudio: Bool) async -> CompletedDictation {
        guard phase == .running else {
            if phase == .idle { end() }
            return CompletedDictation(text: "", wav: nil, receivedAudio: false)
        }
        phase = .finishing
        limitTask?.cancel()
        let deadline = ContinuousClock.now.advanced(by: limits.finalizeTimeout)
        await stopAudio()
        // Forward the chunks still queued in the ended audio stream, then end the input.
        _ = await Self.wait(for: audioTask, until: deadline)
        input?.finish()
        input = nil
        let finalized = await Self.wait(for: transcription, until: deadline)
        guard phase == .finishing else { return CompletedDictation(text: "", wav: nil, receivedAudio: false) }
        cancelTranscription()
        let text = accumulator.current.text
        let wav = retainAudio ? DictationWAV.encode(buffered, input: format) : nil
        let chunks = buffered.count
        end()
        Self.log.info("dictation finished chunks=\(chunks, privacy: .public) chars=\(text.count, privacy: .public) finalized=\(finalized, privacy: .public)")
        return CompletedDictation(text: text, wav: wav, receivedAudio: chunks > 0)
    }

    /// Stops audio, cancels the transcription, drops buffers and text.
    public func cancel() async {
        guard phase != .ended else { return }
        phase = .ended
        limitTask?.cancel()
        cancelTranscription()
        await stopAudio()
        audioTask?.cancel()
        end()
        Self.log.info("dictation cancelled")
    }

    /// Restarts transcription in `l`. Same analyzer format: the audio heard so far is replayed into the
    /// new transcription, then live audio continues. Different format: capture restarts in the new
    /// format and the old audio is dropped. The text so far is reset either way (an empty
    /// `.transcript` is emitted). Every suspension re-checks that the session is still live before
    /// starting anything.
    public func switchLocale(_ l: DictationLocale) async throws {
        guard isListening, l != locale else { return }
        switchGeneration += 1
        let token = switchGeneration
        let newFormat: AVAudioFormat
        do {
            newFormat = try await transcriber.format(for: l)
        } catch {
            throw Self.mapped(error) { .transcriber($0) }
        }
        guard isListening, token == switchGeneration else { return }
        cancelTranscription()
        accumulator = TranscriptAccumulator()
        emit(.transcript(accumulator.current))
        locale = l
        if let format, newFormat == format {
            beginTranscription(replay: buffered)
            if !buffered.isEmpty { emit(.listening(l)) }
            Self.log.info("dictation switched locale=\(l.rawValue, privacy: .public) replayed=\(self.buffered.count, privacy: .public)")
        } else {
            await stopAudio()
            // `cancel()`, `finish()` or the cap may have run while the old capture stopped: never
            // restart the analyzer or the microphone for a session that is no longer live.
            guard phase == .running, !limitHit, token == switchGeneration else { return }
            audioGeneration += 1  // ignore whatever the old capture still had queued
            buffered = []
            format = newFormat
            beginTranscription(replay: [])
            do {
                try await startAudio(format: newFormat)
            } catch {
                let e = Self.mapped(error) { .audio($0) }
                guard phase == .running else { throw e }
                emit(.failed(e))
                await stopListening()
                throw e
            }
            Self.log.info("dictation switched locale=\(l.rawValue, privacy: .public) restarted capture")
        }
    }

    // MARK: Audio

    private var isListening: Bool { phase == .running && audioRunning && !limitHit }

    private func startAudio(format: AVAudioFormat) async throws {
        audioGeneration += 1
        let generation = audioGeneration
        audioRunning = true  // a cancel during `audio.start` must stop it
        let stream: AsyncStream<AudioEvent>
        do {
            stream = try await audio.start(format: format)
        } catch {
            await stopAudio()
            throw Self.mapped(error) { .audio($0) }
        }
        guard audioRunning, generation == audioGeneration else {
            // A cancel, finish or stop ran while `audio.start` was still running: its `audio.stop()`
            // may have landed before the engine started. Stop again (idempotent) so the microphone
            // never stays on. A newer capture marked running is left alone.
            if !audioRunning { await audio.stop() }
            return
        }
        audioTask = Task {
            for await event in stream { await self.handle(event, generation: generation) }
            await self.audioEnded(generation: generation)
        }
    }

    /// Calls `audio.stop()` once per start.
    private func stopAudio() async {
        guard audioRunning else { return }
        audioRunning = false
        await audio.stop()
    }

    private func handle(_ event: AudioEvent, generation: Int) async {
        guard generation == audioGeneration, phase == .running || phase == .finishing else { return }
        switch event {
        case .chunk(let c):
            // Chunks queued before a stop still go in; nothing goes in after the cap.
            guard !limitHit else { return }
            let first = buffered.isEmpty
            buffered.append(c)
            if first, isListening {
                emit(.listening(locale))
                Self.log.info("dictation listening locale=\(self.locale.rawValue, privacy: .public)")
            }
            input?.yield(c)
        case .level(let l):
            guard audioRunning else { return }
            emit(.level(l))
        case .interrupted:
            guard audioRunning, phase == .running else { return }
            Self.log.info("dictation audio interrupted")
            emit(.interrupted)
            await stopListening()
        }
    }

    /// The stream ended without the session stopping it: treat it as an interruption.
    private func audioEnded(generation: Int) async {
        guard generation == audioGeneration, audioRunning, phase == .running else { return }
        Self.log.info("dictation audio ended unexpectedly")
        emit(.interrupted)
        await stopListening()
    }

    private func reachLimit() async {
        guard phase == .running, !limitHit else { return }
        limitHit = true
        Self.log.info("dictation reached the duration cap")
        emit(.limitReached)
        await stopListening()
    }

    /// Stops the microphone but keeps the text; the transcriber finalizes what it heard.
    private func stopListening() async {
        limitTask?.cancel()
        input?.finish()
        input = nil
        await stopAudio()
    }

    // MARK: Transcription

    private func beginTranscription(replay: [AnalyzerInput]) {
        guard let format else { return }
        transcriptionGeneration += 1
        let generation = transcriptionGeneration
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        for c in replay { continuation.yield(c) }
        input = continuation
        let results = transcriber.transcribe(locale, format: format, input: stream)
        transcription = Task {
            do {
                for try await r in results { self.apply(r, generation: generation) }
            } catch {
                await self.transcriptionFailed(error, generation: generation)
            }
        }
    }

    private func cancelTranscription() {
        transcriptionGeneration += 1
        transcription?.cancel()
        transcription = nil
        input?.finish()
        input = nil
    }

    private func apply(_ r: TranscriberResult, generation: Int) {
        guard generation == transcriptionGeneration, phase == .running || phase == .finishing else { return }
        emit(.transcript(accumulator.apply(r)))
    }

    private func transcriptionFailed(_ error: any Error, generation: Int) async {
        guard generation == transcriptionGeneration, phase == .running else { return }
        let e = Self.mapped(error) { .transcriber($0) }
        Self.log.error("dictation transcriber failed: \(String(describing: type(of: error)), privacy: .public)")
        emit(.failed(e))
        await stopListening()
    }

    // MARK: Helpers

    private func emit(_ e: Event) { sink.yield(e) }

    private func end() {
        phase = .ended
        limitTask?.cancel()
        limitTask = nil
        buffered = []
        accumulator = TranscriptAccumulator()
        sink.finish()
    }

    /// Waits for `task` until `deadline`; on timeout cancels it (which ends a stream consumer).
    private static func wait(for task: Task<Void, Never>?, until deadline: ContinuousClock.Instant) async -> Bool {
        guard let task else { return true }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { await task.value; return true }
            group.addTask { try? await Task.sleep(until: deadline, clock: .continuous); return false }
            let done = await group.next() ?? false
            if !done { task.cancel() }
            group.cancelAll()
            return done
        }
    }

    private static func mapped(_ error: any Error, _ wrap: (String) -> DictationError) -> DictationError {
        if let e = error as? DictationError { return e }
        return wrap(String(describing: type(of: error)) + ": " + (error as NSError).localizedDescription)
    }

    private static func kind(_ e: DictationError) -> String {
        switch e {
        case .noInputDevice: "noInputDevice"
        case .audio: "audio"
        case .noCompatibleFormat: "noCompatibleFormat"
        case .transcriber: "transcriber"
        case .alreadyRunning: "alreadyRunning"
        case .tooManyReservedLanguages: "tooManyReservedLanguages"
        }
    }
}
