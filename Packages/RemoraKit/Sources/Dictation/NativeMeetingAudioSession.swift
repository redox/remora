import AVFoundation
import Foundation
import Speech
import Synchronization

public enum MeetingAudioSource: Sendable, Hashable { case microphone, remote }

public struct MeetingAudioSegment: Sendable, Equatable {
    public let source: MeetingAudioSource
    public let startSeconds: TimeInterval
    public let endSeconds: TimeInterval
    public let text: String
}

@MainActor protocol MeetingAudioHardware {
    func startRemote(bundleID: String, pid: Int32, output: MeetingAudioInput) throws
    func startMicrophone(output: MeetingAudioInput) throws
    func stopMicrophone()
    func stopRemote()
}

/// One bounded pipe per source. A slow analyzer interrupts the recording instead of silently losing
/// speech or accumulating audio. Neither pipe retains a replay buffer.
final class MeetingAudioInput: Sendable {
    let format: AVAudioFormat
    let origin: UInt64
    let stream: AsyncStream<AnalyzerInput>
    private let sink: AsyncStream<AnalyzerInput>.Continuation
    private enum State: Equatable { case pending, open(UInt64), closed }
    private let state = Mutex<State>(.pending)
    private let onFailure: @Sendable () -> Void
    private let cloudStaging: MeetingCloudStaging?

    init(format: AVAudioFormat, origin: UInt64, cloudStaging: MeetingCloudStaging? = nil,
         onFailure: @escaping @Sendable () -> Void) {
        self.cloudStaging = cloudStaging
        self.format = format
        self.origin = origin
        self.onFailure = onFailure
        (stream, sink) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(32))
    }

    func open(at hostTime: UInt64) {
        state.withLock { state in
            if state == .pending { state = .open(hostTime) }
        }
    }

    func accepts(hostTime: UInt64) -> Bool {
        state.withLock { state in
            guard case .open(let verifiedAt) = state else { return false }
            return hostTime >= verifiedAt
        }
    }

    func conversionEpoch(hostTime: UInt64) -> UInt64? {
        guard hostTime >= origin, accepts(hostTime: hostTime) else { return nil }
        guard let cloudStaging else { return 0 }
        return cloudStaging.conversionEpoch(at: AVAudioTime.seconds(forHostTime: hostTime - origin))
    }

    func append(_ chunk: AnalyzerInput, hostTime: UInt64, capturedDuration: TimeInterval? = nil) {
        guard hostTime >= origin, accepts(hostTime: hostTime) else { return }
        if let cloudStaging {
            let start = AVAudioTime.seconds(forHostTime: hostTime - origin)
            if !cloudStaging.append(chunk, at: start, capturedDuration: capturedDuration) { interrupt() }
        } else if case .dropped = sink.yield(chunk) {
            interrupt()
        }
    }

    func interrupt() {
        if close() { onFailure() }
    }

    @discardableResult func close() -> Bool {
        state.withLock { state in
            guard state != .closed else { return false }
            state = .closed
            sink.finish()
            return true
        }
    }
}

/// A single meeting. Muting tears down the input device while the client-output tap keeps running.
/// Cancel discards pending results. Stop closes the devices first and accepts the analyzers' finals.
@MainActor public final class NativeMeetingAudioSession {
    private enum Phase { case idle, starting, recording, awaitingFinalVerification, draining, ended }
    private var phase = Phase.idle
    private let hardware: any MeetingAudioHardware
    private let transcriber: any Transcriber
    private let hostTime: @Sendable () -> UInt64
    private var cloudChannels: [MeetingAudioSource: MeetingCloudChannel] = [:]
    public private(set) var transcriptionInterrupted = false
    public private(set) var interruptedSource: MeetingAudioSource?
    private var origin: UInt64?
    private var micAllowed = false
    private var micActive = false
    private var inputs: [MeetingAudioSource: MeetingAudioInput] = [:]
    private var tasks: [Task<Void, Never>] = []
    private var report: (@MainActor (MeetingAudioSegment) -> Void)?
    private var interruption: (@MainActor () -> Void)?

    public convenience init() {
        self.init(hardware: SystemMeetingAudioHardware(), transcriber: SpeechAnalyzerTranscriber())
    }

    init(hardware: any MeetingAudioHardware, transcriber: any Transcriber,
         hostTime: @escaping @Sendable () -> UInt64 = { mach_absolute_time() }) {
        self.hostTime = hostTime
        self.hardware = hardware
        self.transcriber = transcriber
    }

    public var elapsedSeconds: TimeInterval {
        guard let origin else { return 0 }
        return AVAudioTime.seconds(forHostTime: hostTime() - origin)
    }

    public func start(bundleID: String, pid: Int32, locale: DictationLocale, micAllowed: Bool,
                      cloudTranscribe: MeetingCloudTranscribe? = nil,
                      verify: @escaping @MainActor () async -> Bool = { true },
                      onSegment: @escaping @MainActor (MeetingAudioSegment) -> Void,
                      onInterrupted: @escaping @MainActor () -> Void) async throws {
        guard phase == .idle else { throw DictationError.alreadyRunning }
        phase = .starting
        self.micAllowed = micAllowed
        report = onSegment
        interruption = onInterrupted
        let origin = hostTime()
        self.origin = origin
        do {
            let format: AVAudioFormat
            if cloudTranscribe != nil {
                format = MeetingCloudStaging.format
            } else {
                format = try await transcriber.format(for: locale)
            }
            try Task.checkCancellation()
            guard phase == .starting else { throw CancellationError() }
            for source in [MeetingAudioSource.remote, .microphone] {
                let cloud = cloudTranscribe.map { _ in MeetingCloudChannel() }
                cloudChannels[source] = cloud
                let input = MeetingAudioInput(format: format, origin: origin, cloudStaging: cloud?.staging) { [weak self] in
                    Task { @MainActor in self?.interrupted(source: source) }
                }
                inputs[source] = input
                if let cloud, let cloudTranscribe {
                    tasks.append(consumeCloud(cloud, source: source, transcribe: cloudTranscribe))
                } else {
                    let results = transcriber.transcribe(locale, format: format, input: input.stream)
                    tasks.append(consumeLocal(results, source: source))
                }
            }
            guard let remote = inputs[.remote] else { throw DictationError.noCompatibleFormat }
            try hardware.startRemote(bundleID: bundleID, pid: pid, output: remote)
            // Core Audio may present a system permission prompt during setup. Discard every buffer
            // until the caller has reverified the joined window, and date admission by sample time.
            guard await verify(), phase == .starting else { throw CancellationError() }
            try Task.checkCancellation()
            let verifiedAt = hostTime()
            for input in inputs.values { input.open(at: verifiedAt) }
            phase = .recording
            try updateMicrophone()
        } catch {
            cancel()
            throw error
        }
    }

    private func consumeLocal(_ results: AsyncThrowingStream<TranscriberResult, any Error>,
                              source: MeetingAudioSource) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                for try await result in results {
                    guard !Task.isCancelled else { return }
                    self?.receive(result, source: source)
                }
                if self?.phase == .recording { self?.transcriberFailed() }
                else if self?.phase == .starting { self?.cancel() }
            } catch {
                if !Task.isCancelled { self?.transcriberFailed() }
            }
        }
    }

    private func consumeCloud(_ channel: MeetingCloudChannel, source: MeetingAudioSource,
                              transcribe: @escaping MeetingCloudTranscribe) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                for await batch in channel.batches {
                    try Task.checkCancellation()
                    if let result = try await MeetingCloudChannel.transcribe(batch, using: transcribe) {
                        self?.receive(result, source: source)
                    }
                }
            } catch {
                if !Task.isCancelled { self?.cloudFailed() }
            }
        }
    }

    /// Only complete buffers predating the beginning of a successful observation are eligible for
    /// upload. A window change or an unverified microphone interval invalidates unconfirmed samples.
    public func confirmVerified(through cutoff: TimeInterval, micAllowed: Bool) {
        guard phase == .recording || phase == .awaitingFinalVerification, cutoff.isFinite else { return }
        if phase == .awaitingFinalVerification { phase = .draining }
        let now = elapsedSeconds
        for (source, cloud) in cloudChannels {
            let accepted = source == .microphone && !micAllowed
                ? cloud.invalidate() : cloud.confirm(through: min(cutoff, now), observedAt: now)
            if !accepted {
                cloudFailed()
                return
            }
        }
    }

    public func invalidateUnverifiedAudio() {
        for cloud in cloudChannels.values where !cloud.invalidate() {
            cloudFailed()
            return
        }
    }

    public func setMicAllowed(_ allowed: Bool) {
        micAllowed = allowed
        do { try updateMicrophone() } catch { interrupted(source: .microphone) }
        if !allowed, cloudChannels[.microphone]?.invalidate() == false { cloudFailed() }
    }

    private func updateMicrophone() throws {
        guard phase == .recording, micAllowed != micActive else { return }
        if micAllowed, let input = inputs[.microphone] {
            try hardware.startMicrophone(output: input)
        } else {
            hardware.stopMicrophone()
        }
        micActive = micAllowed
    }

    private func receive(_ result: TranscriberResult, source: MeetingAudioSource) {
        guard phase == .recording || phase == .awaitingFinalVerification || phase == .draining, result.isFinal,
              let start = result.startSeconds, let end = result.endSeconds,
              start.isFinite, end.isFinite, start >= 0, end >= start else { return }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        report?(.init(source: source, startSeconds: start, endSeconds: end, text: text))
    }

    private func interrupted(source: MeetingAudioSource? = nil) {
        if phase == .starting {
            cancel()
            return
        }
        guard phase == .recording else { return }
        interruptedSource = source
        closeInputs()
        interruption?()
    }

    private func transcriberFailed() {
        guard phase != .ended else { return }
        transcriptionInterrupted = true
        interrupted()
    }

    private func cloudFailed() {
        guard phase != .ended else { return }
        transcriptionInterrupted = true
        for task in tasks { task.cancel() }
        for cloud in cloudChannels.values { cloud.cancel() }
        interrupted()
    }

    private func closeInputs() {
        phase = .draining
        hardware.stopMicrophone()
        micActive = false
        hardware.stopRemote()
        for input in inputs.values { input.close() }
    }

    /// Manual stop closes both devices immediately. One fresh same-call observation can then
    /// approve the staging interval, including a short utterance before the first regular poll.
    public func closeForFinalVerification() {
        if phase == .idle || phase == .starting {
            cancel()
        } else if phase == .recording {
            closeInputs()
            phase = .awaitingFinalVerification
        }
    }

    public func stop() async {
        guard phase != .ended else { return }
        if phase == .starting {
            cancel()
            return
        }
        if phase == .awaitingFinalVerification { phase = .draining }
        if phase != .draining { closeInputs() }
        for cloud in cloudChannels.values where !cloud.finish() {
            cloudFailed()
            break
        }
        let tasks = self.tasks
        // Allow up to four 15-second requests per track: in flight, two queued and the final partial.
        let duration: Duration = cloudChannels.isEmpty ? .seconds(5) : .seconds(65)
        let timeout = Task {
            do { try await Task.sleep(for: duration) } catch { return }
            if !cloudChannels.isEmpty { transcriptionInterrupted = true }
            for task in tasks { task.cancel() }
        }
        for task in tasks { await task.value }
        timeout.cancel()
        finish()
    }

    public func cancel() {
        guard phase != .ended else { return }
        closeInputs()
        for cloud in cloudChannels.values { cloud.cancel() }
        for task in tasks { task.cancel() }
        finish()
    }

    private func finish() {
        phase = .ended
        tasks.removeAll()
        inputs.removeAll()
        cloudChannels.removeAll()
        report = nil
        interruption = nil
    }

    isolated deinit { cancel() }
}
