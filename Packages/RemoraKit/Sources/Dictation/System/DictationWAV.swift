import AVFoundation
import Foundation
import Speech

/// Packs the existing microphone buffers into 16 kHz mono PCM WAV. No files or extra recording.
enum DictationWAV {
    private static let sampleRate: UInt32 = 16_000
    private static let bytesPerFrame = 2
    private static let headerSize = 44

    static func encode(_ chunks: [AnalyzerInput], input: AVAudioFormat?) -> Data? {
        guard !chunks.isEmpty, let input,
              let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate),
                                         channels: 1, interleaved: true) else { return nil }
        var pcm = Data()
        if input == output {
            for chunk in chunks {
                guard !Task.isCancelled, append(chunk.buffer, to: &pcm) else { return nil }
            }
        } else {
            guard let converter = AVAudioConverter(from: input, to: output) else { return nil }
            converter.downmix = true
            // A fixed output size bounds each allocation; the converter pulls as many inputs as it needs.
            guard let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 4096) else { return nil }
            var next = 0
            while !Task.isCancelled {
                let status = converter.convert(to: buffer, error: nil) { _, state in
                    guard next < chunks.count else {
                        state.pointee = .endOfStream
                        return nil
                    }
                    let chunk = chunks[next]
                    next += 1
                    state.pointee = .haveData
                    return chunk.buffer
                }
                guard status != .error, append(buffer, to: &pcm) else { return nil }
                if status == .endOfStream { break }
                if buffer.frameLength == 0 { return nil }
            }
        }
        guard !Task.isCancelled, !pcm.isEmpty else { return nil }
        return wrap(pcm)
    }

    private static func append(_ buffer: AVAudioPCMBuffer, to pcm: inout Data) -> Bool {
        let count = Int(buffer.frameLength) * bytesPerFrame
        guard count + pcm.count <= OpenAITranscription.maximumAudioBytes - headerSize,
              let samples = buffer.int16ChannelData else { return false }
        pcm.append(UnsafeBufferPointer(start: UnsafeRawPointer(samples[0]).assumingMemoryBound(to: UInt8.self), count: count))
        return true
    }

    private static func wrap(_ pcm: Data) -> Data {
        var wav = Data("RIFF".utf8)
        append(UInt32(pcm.count + headerSize - 8), to: &wav)
        wav.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16), to: &wav)                       // PCM format chunk size
        append(UInt16(1), to: &wav)                        // PCM
        append(UInt16(1), to: &wav)                        // mono
        append(sampleRate, to: &wav)
        append(sampleRate * UInt32(bytesPerFrame), to: &wav)
        append(UInt16(bytesPerFrame), to: &wav)
        append(UInt16(16), to: &wav)                       // bits per sample
        wav.append(contentsOf: "data".utf8)
        append(UInt32(pcm.count), to: &wav)
        wav.append(pcm)
        return wav
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}
