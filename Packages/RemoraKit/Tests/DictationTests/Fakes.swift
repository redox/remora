import AVFoundation
import CoreMedia
import Speech
import Synchronization
@testable import Dictation

/// 16 kHz mono Int16, the shape the analyzer usually asks for: the fakes' default analyzer format.
/// (`AnalyzerInput(buffer:)` traps on a deinterleaved Float32 buffer.)
let format16k = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
let format48k = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: true)!

/// A 160-frame silent buffer at 16 kHz mono, tagged through `bufferStartTime` so a fake can tell chunks apart
/// without reading the buffer.
func chunk(_ tag: Int) -> AnalyzerInput {
    let buffer = AVAudioPCMBuffer(pcmFormat: format16k, frameCapacity: 160)!
    buffer.frameLength = 160
    buffer.int16ChannelData![0].update(repeating: 0, count: 160)
    return AnalyzerInput(buffer: buffer, bufferStartTime: CMTime(value: CMTimeValue(tag), timescale: 16_000))
}

/// A lock-protected value that closures can capture (a `Mutex` itself is not copyable).
final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>
    init(_ value: Value) { mutex = Mutex(value) }
    func withLock<R>(_ body: (inout Value) -> R) -> R { mutex.withLock { body(&$0) } }
}

/// Audio capture driven by the test: `send` pushes events into the stream returned by the last `start`.
actor FakeAudioCapture: AudioCapturing {
    private(set) var startCalls = 0
    private(set) var stopCalls = 0
    private(set) var formats: [AVAudioFormat] = []
    private var startError: DictationError?
    private var continuation: AsyncStream<AudioEvent>.Continuation?

    init(startError: DictationError? = nil) { self.startError = startError }

    func start(format: AVAudioFormat) async throws -> AsyncStream<AudioEvent> {
        startCalls += 1
        formats.append(format)
        if startGated { await withCheckedContinuation { startWaiters.append($0) } }
        if let startError { throw startError }
        let (stream, continuation) = AsyncStream<AudioEvent>.makeStream()
        self.continuation = continuation
        return stream
    }

    private var stopGated = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    func stop() async {
        stopCalls += 1
        if stopGated { await withCheckedContinuation { stopWaiters.append($0) } }
        continuation?.finish()
        continuation = nil
    }

    private var startGated = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    /// Makes the next `start()` calls suspend until `releaseStart()`.
    func gateStart() { startGated = true }
    func releaseStart() {
        startGated = false
        let waiters = startWaiters
        startWaiters = []
        for w in waiters { w.resume() }
    }

    /// Makes the next `stop()` calls suspend until `releaseStop()`.
    func gateStop() { stopGated = true }
    func releaseStop() {
        stopGated = false
        let waiters = stopWaiters
        stopWaiters = []
        for w in waiters { w.resume() }
    }

    func send(_ event: AudioEvent) { continuation?.yield(event) }
    func sendChunk(_ tag: Int) { send(.chunk(chunk(tag))) }
}

struct FakeTranscriberError: Error {}

/// One scripted transcription session.
struct TranscriberScript: Sendable {
    /// Results yielded right after the Nth chunk (1-based) is received.
    var afterChunks: [Int: [TranscriberResult]] = [:]
    /// Results yielded once the input stream ends.
    var onInputEnd: [TranscriberResult] = []
    /// Never finish after the input ends (finalization hangs).
    var hangOnInputEnd = false
    /// Throw right after the Nth chunk.
    var failAfterChunk: Int?
}

final class FakeTranscriber: Transcriber {
    struct Session: Sendable {
        var locale: DictationLocale
        var format: AVAudioFormat
        /// `bufferStartTime` tags of the chunks received, in order.
        var chunkTags: [Int64] = []
        var inputEnded = false
        var cancelled = false
    }

    private struct State {
        var sessions: [Session] = []
        var prewarmed: [DictationLocale] = []
    }

    private let scripts: [TranscriberScript]
    private let formats: [DictationLocale: AVAudioFormat]
    private let state = Locked(State())

    init(scripts: [TranscriberScript] = [], formats: [DictationLocale: AVAudioFormat] = [:]) {
        self.scripts = scripts
        self.formats = formats
    }

    var sessions: [Session] { state.withLock { $0.sessions } }

    func format(for l: DictationLocale) async throws -> AVAudioFormat { formats[l] ?? format16k }

    func prewarm(_ l: DictationLocale) async { state.withLock { $0.prewarmed.append(l) } }

    func transcribe(_ l: DictationLocale, format: AVAudioFormat,
                    input: AsyncStream<AnalyzerInput>) -> AsyncThrowingStream<TranscriberResult, any Error> {
        let index = state.withLock { s in
            s.sessions.append(Session(locale: l, format: format))
            return s.sessions.count - 1
        }
        let script = index < scripts.count ? scripts[index] : TranscriberScript()
        let state = self.state
        return AsyncThrowingStream { continuation in
            let task = Task {
                var count = 0
                for await c in input {
                    count += 1
                    let tag = c.bufferStartTime?.value ?? -1
                    state.withLock { $0.sessions[index].chunkTags.append(tag) }
                    for r in script.afterChunks[count] ?? [] { continuation.yield(r) }
                    if script.failAfterChunk == count {
                        continuation.finish(throwing: FakeTranscriberError())
                        return
                    }
                }
                if Task.isCancelled { return }
                state.withLock { $0.sessions[index].inputEnded = true }
                for r in script.onInputEnd { continuation.yield(r) }
                if script.hangOnInputEnd {
                    while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                    return
                }
                continuation.finish()
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination { state.withLock { $0.sessions[index].cancelled = true } }
                task.cancel()
            }
        }
    }
}

/// Collects a session's events as they arrive.
final class EventLog: Sendable {
    private let events = Locked<[DictationSession.Event]>([])
    private let ended = Locked(false)

    init(_ stream: AsyncStream<DictationSession.Event>) {
        Task { [events, ended] in
            for await e in stream { events.withLock { $0.append(e) } }
            ended.withLock { $0 = true }
        }
    }

    var all: [DictationSession.Event] { events.withLock { $0 } }
    var isEnded: Bool { ended.withLock { $0 } }

    func contains(_ e: DictationSession.Event) -> Bool { all.contains(e) }
}

/// Polls `condition` until it holds or `timeout` elapses.
func eventually(timeout: Duration = .seconds(2), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await condition()
}

extension TranscriberResult {
    static func final(_ t: String) -> TranscriberResult { .init(text: t, isFinal: true) }
    static func volatile(_ t: String) -> TranscriberResult { .init(text: t, isFinal: false) }
}
