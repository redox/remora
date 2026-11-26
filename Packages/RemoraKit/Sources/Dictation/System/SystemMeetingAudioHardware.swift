import AVFoundation
import CoreMedia
import Speech
import Synchronization

/// Revocation waits for an in-flight callback. A delayed callback from a previous tap or a device
/// buffer that includes audio from before the verified unmute cannot enter the analyzer.
final class MeetingMicrophoneGate: Sendable {
    private let openedAt: UInt64
    private let open = Mutex(true)

    init(openedAt: UInt64) { self.openedAt = openedAt }

    func withPermission(hostTime: UInt64, _ work: () -> Void) {
        open.withLock { allowed in
            if allowed, hostTime >= openedAt { work() }
        }
    }

    func close() { open.withLock { $0 = false } }
}

/// Each instance belongs to a single serial device callback. Conversion finishes inside the callback
/// while the device still owns its input. The bounded pipe receives only an independently owned buffer.
final class MeetingPCMConverter {
    private let converter: AVAudioConverter
    private let output: MeetingAudioInput
    private var nextFrame: Int64?
    private var epoch: UInt64?

    init(input: AVAudioFormat, output: MeetingAudioInput) throws {
        guard input.sampleRate > 0, input.channelCount > 0, output.format.sampleRate > 0,
              let converter = AVAudioConverter(from: input, to: output.format) else {
            throw DictationError.noCompatibleFormat
        }
        converter.downmix = input.channelCount > output.format.channelCount
        converter.primeMethod = .none
        self.converter = converter
        self.output = output
    }

    func append(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        guard let currentEpoch = output.conversionEpoch(hostTime: hostTime), buffer.frameLength > 0 else { return }
        if epoch != currentEpoch {
            // A sample-rate converter can retain filter history. Reset it before accepting the
            // first buffer after a privacy boundary, so earlier samples cannot leak into that buffer.
            converter.reset()
            nextFrame = nil
            epoch = currentEpoch
        }
        let rate = output.format.sampleRate
        let size = (Double(buffer.frameLength) * rate / converter.inputFormat.sampleRate).rounded(.up) + 1
        guard size <= 65_536,
              let converted = AVAudioPCMBuffer(pcmFormat: output.format, frameCapacity: AVAudioFrameCount(size)) else {
            output.interrupt()
            return
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error else {
            output.interrupt()
            return
        }
        guard converted.frameLength > 0 else { return }
        // Preserve silent device gaps and mute intervals on the shared host clock. Between gaps use
        // the actual sample count, since tiny differences between device clocks are not word boundaries.
        let ticks = hostTime > output.origin ? hostTime - output.origin : 0
        let measured = Int64((AVAudioTime.seconds(forHostTime: ticks) * rate).rounded())
        let start: Int64
        if let nextFrame, measured <= nextFrame + Int64(rate / 100) {
            start = nextFrame
        } else {
            start = measured
        }
        nextFrame = start + Int64(converted.frameLength)
        let time = CMTime(value: start, timescale: Int32(rate))
        output.append(AnalyzerInput(buffer: converted, bufferStartTime: time), hostTime: hostTime,
                      capturedDuration: Double(buffer.frameLength) / converter.inputFormat.sampleRate)
    }
}

@MainActor final class SystemMeetingAudioHardware: MeetingAudioHardware {
    private let tap = MeetingClientAudioTap()
    private var microphone: AVAudioEngine?
    private var microphoneGate: MeetingMicrophoneGate?
    private var configurationObserver: (any NSObjectProtocol)?

    func startRemote(bundleID: String, pid: Int32, output: MeetingAudioInput) throws {
        try tap.start(bundleID: bundleID, pid: pid, output: output)
    }

    func startMicrophone(output: MeetingAudioInput) throws {
        // Never trigger a microphone prompt in response to a call's mute control changing.
        guard SystemMicrophonePermission().status() == .granted else {
            throw DictationError.audio("Microphone permission is unavailable.")
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let gate = MeetingMicrophoneGate(openedAt: mach_absolute_time())
        let callback = try Self.microphoneCallback(format: format, output: output, gate: gate)
        microphoneGate = gate
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: callback)
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { _ in
            gate.withPermission(hostTime: mach_absolute_time()) { output.interrupt() }
        }
        microphone = engine
        do {
            engine.prepare()
            try engine.start()
        } catch {
            stopMicrophone()
            throw error
        }
    }

    private nonisolated static func microphoneCallback(format: AVAudioFormat,
                                                        output: MeetingAudioInput,
                                                        gate: MeetingMicrophoneGate) throws -> AVAudioNodeTapBlock {
        let converter = try MeetingPCMConverter(input: format, output: output)
        return { buffer, time in
            guard time.isHostTimeValid else { return }
            gate.withPermission(hostTime: time.hostTime) { converter.append(buffer, hostTime: time.hostTime) }
        }
    }

    func stopMicrophone() {
        microphoneGate?.close()
        microphoneGate = nil
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        microphone?.inputNode.removeTap(onBus: 0)
        microphone?.stop()
        microphone = nil
    }

    func stopRemote() { tap.stop() }
}
