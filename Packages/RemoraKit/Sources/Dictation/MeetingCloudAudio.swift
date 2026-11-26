import AVFoundation
import Foundation
import Speech
import Synchronization

/// This closure runs immediately before a verified WAV is sent. The owner rechecks permission,
/// provider and source policy there, and uses the user's project-key transcription client.
public typealias MeetingCloudTranscribe = @MainActor @Sendable (Data) async throws -> String

struct MeetingCloudPiece: Sendable {
    let audio: AnalyzerInput
    let start: TimeInterval
    let end: TimeInterval
}

/// Device callbacks stage only the interval since the last successful call-window observation.
/// A mute or window event discards it, including late callbacks dated before re-verification.
final class MeetingCloudStaging: Sendable {
    private struct State: Sendable {
        var pending: [MeetingCloudPiece] = []
        var suspended = false
        // Admission starts at the most recent re-verification after a privacy boundary. A
        // routine check only advances the end of the verified interval, since callbacks can lag.
        var minimumStart: TimeInterval = 0
        var verifiedThrough: TimeInterval = 0
        var frames = 0
        var epoch: UInt64 = 0
    }

    private let state = Mutex(State())
    static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    func conversionEpoch(at start: TimeInterval) -> UInt64? {
        state.withLock { state in
            !state.suspended && start >= state.minimumStart ? state.epoch : nil
        }
    }

    func append(_ input: AnalyzerInput, at start: TimeInterval, capturedDuration: TimeInterval? = nil) -> Bool {
        let count = Int(input.buffer.frameLength)
        guard count > 0, start.isFinite, start >= 0, input.buffer.format == Self.format else { return false }
        return state.withLock { state in
            guard !state.suspended, start >= state.minimumStart else { return true }
            guard state.pending.count < 2048, state.frames + count <= 16 * 16_000 else { return false }
            let end = start + max(Double(count) / Self.format.sampleRate, capturedDuration ?? 0)
            state.pending.append(MeetingCloudPiece(audio: input, start: start, end: end))
            state.frames += count
            return true
        }
    }

    /// Return any late arrivals already covered by the last verification before closing this interval.
    @discardableResult func invalidate() -> [MeetingCloudPiece] {
        state.withLock { state in
            let verified = Array(state.pending.prefix { $0.end <= state.verifiedThrough })
            state.pending.removeAll()
            state.frames = 0
            state.suspended = true
            state.epoch &+= 1
            state.verifiedThrough = 0
            return verified
        }
    }

    func confirm(through cutoff: TimeInterval, observedAt now: TimeInterval) -> [MeetingCloudPiece] {
        state.withLock { state in
            guard cutoff.isFinite, now.isFinite, cutoff <= now else { return [] }
            if state.suspended {
                state.suspended = false
                state.minimumStart = now
                return []
            }
            guard cutoff >= state.minimumStart, cutoff >= state.verifiedThrough else { return [] }
            let confirmed = Array(state.pending.prefix { $0.end <= cutoff })
            state.pending.removeFirst(confirmed.count)
            state.frames -= confirmed.reduce(0) { $0 + Int($1.audio.buffer.frameLength) }
            state.verifiedThrough = cutoff
            return confirmed
        }
    }
}

/// The upload consumer owns one batch and can queue two more per source. Audio from overlapping
/// speakers stays on separate tracks. A discontinuity starts a fresh timestamped segment.
@MainActor final class MeetingCloudChannel {
    nonisolated let staging = MeetingCloudStaging()
    let batches: AsyncStream<[MeetingCloudPiece]>
    private let sink: AsyncStream<[MeetingCloudPiece]>.Continuation
    private var batch: [MeetingCloudPiece] = []

    init() {
        // Reserve the third slot for a partial batch when the devices stop.
        (batches, sink) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(3))
    }

    func confirm(through cutoff: TimeInterval, observedAt now: TimeInterval) -> Bool {
        enqueue(staging.confirm(through: cutoff, observedAt: now))
    }

    func invalidate() -> Bool {
        enqueue(staging.invalidate())
    }

    private func enqueue(_ pieces: [MeetingCloudPiece], finishing: Bool = false) -> Bool {
        for piece in pieces {
            if let previous = batch.last, piece.start - previous.end > 0.25, !flush(final: finishing) { return false }
            batch.append(piece)
            if let first = batch.first, piece.end - first.start >= 10 || batch.count >= 2048 {
                if !flush(final: finishing) { return false }
            }
        }
        return true
    }

    func finish() -> Bool {
        let complete = enqueue(staging.invalidate(), finishing: true) && flush(final: true)
        sink.finish()
        return complete
    }

    func cancel() {
        staging.invalidate()
        batch.removeAll()
        sink.finish()
    }

    private func flush(final: Bool = false) -> Bool {
        guard !batch.isEmpty else { return true }
        defer { batch.removeAll() }
        if case .enqueued(let remaining) = sink.yield(batch) { return final || remaining > 0 }
        return false
    }

    /// Check for silence before encoding. A no-speech response for nonzero input is also a normal
    /// result. Permission checks in the caller happen after WAV encoding and before each request.
    nonisolated static func transcribe(_ batch: [MeetingCloudPiece],
                                       using upload: MeetingCloudTranscribe) async throws -> TranscriberResult? {
        guard let first = batch.first, let last = batch.last else { return nil }
        guard batch.contains(where: { piece in
            let buffer = piece.audio.buffer
            guard let samples = buffer.int16ChannelData else { return false }
            return UnsafeBufferPointer(start: samples[0], count: Int(buffer.frameLength)).contains { $0 != 0 }
        }) else { return nil }
        try Task.checkCancellation()
        guard let wav = DictationWAV.encode(batch.map(\.audio), input: MeetingCloudStaging.format) else {
            throw OpenAITranscription.Failure.invalidAudio
        }
        try Task.checkCancellation()
        do {
            let text = try await upload(wav)
            try Task.checkCancellation()
            return TranscriberResult(text: text, isFinal: true, startSeconds: first.start, endSeconds: last.end)
        } catch OpenAITranscription.Failure.emptyTranscript {
            return nil
        }
    }
}
