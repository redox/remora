import AVFoundation
import Foundation
import os
import Speech

/// Microphone capture through an `AVAudioEngine` input tap, converted to the analyzer's format.
///
/// Audio stays in memory: each converted buffer goes straight into the stream; nothing is written to
/// disk. Voice processing stays off, so other apps' audio is not ducked. `stop` (also run when the
/// consumer drops the stream, and on deinit) removes the tap and stops the engine.
public actor EngineAudioCapture: AudioCapturing {
    private static let log = Logger(subsystem: "dev.remora", category: "dictation")

    private var engine: AVAudioEngine?
    private var continuation: AsyncStream<AudioEvent>.Continuation?
    private var observer: (any NSObjectProtocol)?
    /// One per `start`, so a stale stream's termination never tears down a newer capture.
    private var generation = 0

    public init() {}

    public func start(format: AVAudioFormat) async throws -> AsyncStream<AudioEvent> {
        teardown()
        generation += 1
        let generation = self.generation
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            Self.log.error("dictation capture: no input device")
            throw DictationError.noInputDevice
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: format) else {
            throw DictationError.audio("No converter from the input format to the analyzer format.")
        }
        if inputFormat.channelCount > format.channelCount {
            converter.downmix = true  // multi-channel interfaces: mix all inputs down, not just channel 1
        }
        let (stream, continuation) = AsyncStream<AudioEvent>.makeStream()
        continuation.onTermination = { [weak self] termination in
            // The consumer went away without stopping capture: stop this capture (and only this one).
            guard case .cancelled = termination, let self else { return }
            Task { await self.stop(generation: generation) }
        }
        // Request shorter callbacks so a quick release leaves less audio queued inside the engine.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat,
                             block: Self.makeTapBlock(converter: converter, continuation: continuation))
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { _ in
            continuation.yield(.interrupted)
        }
        self.engine = engine
        self.continuation = continuation
        engine.prepare()
        do {
            try engine.start()
        } catch {
            teardown()
            Self.log.error("dictation capture: engine failed to start")
            throw DictationError.audio((error as NSError).localizedDescription)
        }
        Self.log.info("dictation capture started in=\(inputFormat.sampleRate, privacy: .public)Hz out=\(format.sampleRate, privacy: .public)Hz")
        return stream
    }

    public func stop() async {
        teardown()
    }

    private func stop(generation: Int) {
        guard generation == self.generation else { return }
        teardown()
    }

    isolated deinit {
        teardown()
    }

    private func teardown() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
            Self.log.info("dictation capture stopped")
        }
        if let continuation {
            self.continuation = nil
            continuation.finish()
        }
    }

    /// Built outside the actor so the block carries no actor isolation: it runs on the audio thread.
    /// The converter is confined to this block (the tap delivers buffers serially).
    private nonisolated static func makeTapBlock(
        converter: AVAudioConverter, continuation: AsyncStream<AudioEvent>.Continuation
    ) -> AVAudioNodeTapBlock {
        let inRate = converter.inputFormat.sampleRate
        let outFormat = converter.outputFormat
        let ratio = outFormat.sampleRate / inRate
        let levelInterval = UInt64(50_000_000)  // ~20 Hz
        var lastLevelAt: UInt64 = 0
        return { buffer, _ in
            let now = DispatchTime.now().uptimeNanoseconds
            if now &- lastLevelAt >= levelInterval, let level = Self.level(of: buffer) {
                lastLevelAt = now
                continuation.yield(.level(level))
            }
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
            guard buffer.frameLength > 0,
                  let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, out.frameLength > 0 else { return }
            continuation.yield(.chunk(AnalyzerInput(buffer: out)))
        }
    }

    /// RMS of the first channel, mapped from −50…0 dBFS to 0…1.
    private nonisolated static func level(of buffer: AVAudioPCMBuffer) -> Float? {
        let n = Int(buffer.frameLength)
        guard n > 0 else { return nil }
        var sum: Float = 0
        if let data = buffer.floatChannelData {
            let stride = buffer.stride
            for i in 0..<n { let s = data[0][i * stride]; sum += s * s }
        } else if let data = buffer.int16ChannelData {
            let stride = buffer.stride
            for i in 0..<n { let s = Float(data[0][i * stride]) / Float(Int16.max); sum += s * s }
        } else {
            return nil
        }
        let rms = (sum / Float(n)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        return min(max((db + 50) / 50, 0), 1)
    }
}
