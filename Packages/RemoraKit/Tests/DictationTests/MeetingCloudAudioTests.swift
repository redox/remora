import AVFoundation
import Foundation
import Speech
import Testing
@testable import Dictation

struct MeetingCloudAudioTests {
    @Test @MainActor func onlyVerifiedBuffersReachTheCloudWithTheirOwnTrackAndTime() async throws {
        let hardware = CloudTestHardware()
        let apple = FakeTranscriber()
        let clock = Locked<UInt64>(1)
        let session = NativeMeetingAudioSession(hardware: hardware, transcriber: apple, hostTime: { clock.withLock { $0 } })
        var segments: [MeetingAudioSegment] = []
        var sent: [Data] = []
        try await session.start(bundleID: "example.meeting", pid: 10, locale: .fr, micAllowed: true,
            cloudTranscribe: { wav in sent.append(wav); return "Some words" },
            onSegment: { segments.append($0) }, onInterrupted: { Issue.record("Unexpected interruption") })
        let remote = try #require(hardware.remote)
        let mic = try #require(hardware.mic)
        remote.append(Self.tone(100), hostTime: remote.origin + AVAudioTime.hostTime(forSeconds: 1))
        mic.append(Self.tone(200), hostTime: mic.origin + AVAudioTime.hostTime(forSeconds: 1))
        clock.withLock { $0 = remote.origin + AVAudioTime.hostTime(forSeconds: 1.5) }
        session.confirmVerified(through: 1.5, micAllowed: true)
        remote.append(Self.tone(300), hostTime: remote.origin + AVAudioTime.hostTime(forSeconds: 2))
        mic.append(Self.tone(400), hostTime: mic.origin + AVAudioTime.hostTime(forSeconds: 2))
        session.setMicAllowed(false)
        clock.withLock { $0 = remote.origin + AVAudioTime.hostTime(forSeconds: 2.5) }
        session.confirmVerified(through: 2.5, micAllowed: false)
        remote.append(Self.tone(500), hostTime: remote.origin + AVAudioTime.hostTime(forSeconds: 3))
        await session.stop()
        #expect(apple.sessions.isEmpty)
        let samples = sent.flatMap { wav in stride(from: 44, to: wav.count, by: 2).map {
            Int(wav[$0]) + Int(wav[$0 + 1]) * 256
        } }
        #expect(Set(samples) == [100, 200, 300])
        #expect(Set(segments.map(\.source)) == [.microphone, .remote])
        #expect(segments.allSatisfy { $0.startSeconds >= 1 && $0.endSeconds < 2.5 })
    }

    @Test @MainActor func aLateDeviceCallbackKeepsTheLastVerifiedAudioWhenTheCallCloses() async throws {
        let hardware = CloudTestHardware()
        let clock = Locked<UInt64>(0)
        let session = NativeMeetingAudioSession(hardware: hardware, transcriber: FakeTranscriber(),
                                                hostTime: { clock.withLock { $0 } })
        var samples: [Int] = []
        try await session.start(bundleID: "example.meeting", pid: 10, locale: .fr, micAllowed: true,
            cloudTranscribe: { wav in
                samples += stride(from: 44, to: wav.count, by: 2).map { Int(wav[$0]) + Int(wav[$0 + 1]) * 256 }
                return "Final word"
            }, onSegment: { _ in }, onInterrupted: { Issue.record("Unexpected interruption") })
        let mic = try #require(hardware.mic)
        clock.withLock { $0 = AVAudioTime.hostTime(forSeconds: 1.2) }
        session.confirmVerified(through: 1, micAllowed: true)
        // Device timestamps precede callback delivery. Only the first buffer ends before the cutoff.
        mic.append(Self.tone(100), hostTime: AVAudioTime.hostTime(forSeconds: 0.98))
        mic.append(Self.tone(200), hostTime: AVAudioTime.hostTime(forSeconds: 0.995))
        mic.append(Self.tone(300), hostTime: AVAudioTime.hostTime(forSeconds: 1.1))
        await session.stop()
        #expect(samples == Array(repeating: 100, count: 160))
    }

    @Test func windowChangesWithholdBothBufferedAndLatePreverificationAudio() {
        let staging = MeetingCloudStaging()
        let chunk = Self.tone(100)
        #expect(staging.append(chunk, at: 1))
        staging.invalidate()
        #expect(staging.append(chunk, at: 2))
        #expect(staging.confirm(through: 2.5, observedAt: 3).isEmpty)
        #expect(staging.append(chunk, at: 2.75))
        #expect(staging.append(chunk, at: 3.5))
        #expect(staging.confirm(through: 4, observedAt: 4.2).map(\.start) == [3.5])
    }

    @Test func invalidationKeepsOnlyLateBuffersFromThePreviouslyVerifiedInterval() {
        let staging = MeetingCloudStaging()
        _ = staging.confirm(through: 1, observedAt: 1.1)
        #expect(staging.append(Self.tone(100), at: 0.98))
        #expect(staging.append(Self.tone(200), at: 1.05))
        #expect(staging.invalidate().map(\.start) == [0.98])
        #expect(staging.invalidate().isEmpty)
        _ = staging.confirm(through: 2, observedAt: 2.2)
        #expect(staging.append(Self.tone(300), at: 1.9))
        #expect(staging.append(Self.tone(400), at: 2.1))
        #expect(staging.append(Self.tone(500), at: 2.3))
        #expect(staging.confirm(through: 3, observedAt: 3.1).map(\.start) == [2.3])
    }

    @Test func aBufferCrossingTheVerificationBoundaryNeedsAnotherObservation() {
        let staging = MeetingCloudStaging()
        #expect(staging.append(Self.tone(100), at: 1))
        #expect(staging.confirm(through: 1.005, observedAt: 1.005).isEmpty)
        #expect(staging.confirm(through: 1.020, observedAt: 1.020).count == 1)
    }

    @Test func missingVerificationCannotGrowAnUnboundedAudioQueue() {
        let staging = MeetingCloudStaging()
        let sample = Self.tone(100)
        var overloaded = false
        for i in 0..<5_000 where !overloaded {
            overloaded = !staging.append(sample, at: Double(i) * 0.01)
        }
        #expect(overloaded)
    }

    @Test func conversionHistoryCannotCrossAWindowInvalidation() throws {
        let staging = MeetingCloudStaging()
        let pipe = MeetingAudioInput(format: format16k, origin: 0, cloudStaging: staging) { Issue.record("Unexpected interruption") }
        pipe.open(at: 0)
        let initial = try #require(pipe.conversionEpoch(hostTime: 0))
        staging.invalidate()
        #expect(pipe.conversionEpoch(hostTime: 0) == nil)
        _ = staging.confirm(through: 1, observedAt: 2)
        #expect(pipe.conversionEpoch(hostTime: AVAudioTime.hostTime(forSeconds: 1.5)) == nil)
        let resumed = try #require(pipe.conversionEpoch(hostTime: AVAudioTime.hostTime(forSeconds: 3)))
        #expect(initial != resumed)
    }

    @Test @MainActor func cancellationPropagatesToAnUploadAndDropsItsLateResult() async throws {
        let hardware = CloudTestHardware()
        let clock = Locked<UInt64>(0)
        let session = NativeMeetingAudioSession(hardware: hardware, transcriber: FakeTranscriber(),
                                                hostTime: { clock.withLock { $0 } })
        let started = Locked(false)
        let cancelled = Locked(false)
        try await session.start(bundleID: "example.meeting", pid: 10, locale: .en, micAllowed: false,
            cloudTranscribe: { _ in
                started.withLock { $0 = true }
                do { try await Task.sleep(for: .seconds(60)) } catch { cancelled.withLock { $0 = true } }
                return "Late result"
            }, onSegment: { _ in Issue.record("Cancelled upload delivered text") }, onInterrupted: {})
        let remote = try #require(hardware.remote)
        remote.append(Self.tone(100), hostTime: 0)
        remote.append(Self.tone(200), hostTime: AVAudioTime.hostTime(forSeconds: 1))
        clock.withLock { $0 = AVAudioTime.hostTime(forSeconds: 2) }
        session.confirmVerified(through: 2, micAllowed: false)
        #expect(await eventually { started.withLock { $0 } })
        session.cancel()
        #expect(await eventually { cancelled.withLock { $0 } })
    }

    @Test @MainActor func failureDuringFinalUploadMarksThePartialTranscript() async throws {
        let hardware = CloudTestHardware()
        let clock = Locked<UInt64>(0)
        let session = NativeMeetingAudioSession(hardware: hardware, transcriber: FakeTranscriber(),
                                                hostTime: { clock.withLock { $0 } })
        try await session.start(bundleID: "example.meeting", pid: 10, locale: .en, micAllowed: false,
            cloudTranscribe: { _ in throw OpenAITranscription.Failure.httpStatus(503) },
            onSegment: { _ in Issue.record("Failed upload delivered text") }, onInterrupted: {})
        hardware.remote?.append(Self.tone(100), hostTime: 0)
        clock.withLock { $0 = AVAudioTime.hostTime(forSeconds: 2) }
        session.confirmVerified(through: 2, micAllowed: false)
        await session.stop()
        #expect(session.transcriptionInterrupted)
    }

    @Test @MainActor func finalConfirmedBatchDrainsEvenWhenTheNetworkQueueIsFull() async throws {
        let hardware = CloudTestHardware()
        let clock = Locked<UInt64>(0)
        let session = NativeMeetingAudioSession(hardware: hardware, transcriber: FakeTranscriber(),
                                                hostTime: { clock.withLock { $0 } })
        var uploads = 0
        try await session.start(bundleID: "example.meeting", pid: 10, locale: .en, micAllowed: false,
            cloudTranscribe: { _ in uploads += 1; return "Words" },
            onSegment: { _ in }, onInterrupted: { Issue.record("Unexpected interruption") })
        for second in 1...3 {
            hardware.remote?.append(Self.tone(100), hostTime: AVAudioTime.hostTime(forSeconds: Double(second)))
        }
        clock.withLock { $0 = AVAudioTime.hostTime(forSeconds: 4) }
        session.confirmVerified(through: 4, micAllowed: false)
        await session.stop()
        #expect(uploads == 3)
        #expect(!session.transcriptionInterrupted)
    }

    @Test @MainActor func manualStopClosesDevicesBeforeOneLastVerificationOfAShortCall() async throws {
        let hardware = CloudTestHardware()
        let clock = Locked<UInt64>(0)
        let session = NativeMeetingAudioSession(hardware: hardware, transcriber: FakeTranscriber(),
                                                hostTime: { clock.withLock { $0 } })
        var sent = 0
        try await session.start(bundleID: "example.meeting", pid: 10, locale: .en, micAllowed: true,
            cloudTranscribe: { wav in sent += wav.count - 44; return "Words" },
            onSegment: { _ in }, onInterrupted: { Issue.record("Unexpected interruption") })
        let remote = try #require(hardware.remote)
        remote.append(Self.tone(100), hostTime: AVAudioTime.hostTime(forSeconds: 1))
        remote.append(Self.tone(200), hostTime: AVAudioTime.hostTime(forSeconds: 2))
        session.closeForFinalVerification()
        #expect(hardware.remote == nil)
        #expect(hardware.mic == nil)
        remote.append(Self.tone(300), hostTime: AVAudioTime.hostTime(forSeconds: 3))
        clock.withLock { $0 = AVAudioTime.hostTime(forSeconds: 4) }
        session.confirmVerified(through: 1.5, micAllowed: true)
        session.confirmVerified(through: 4, micAllowed: true)
        await session.stop()
        #expect(sent == 320)
    }

    static func tone(_ value: Int16) -> AnalyzerInput {
        let buffer = AVAudioPCMBuffer(pcmFormat: format16k, frameCapacity: 160)!
        buffer.frameLength = 160
        buffer.int16ChannelData![0].update(repeating: value, count: 160)
        return AnalyzerInput(buffer: buffer)
    }
}

@MainActor private final class CloudTestHardware: MeetingAudioHardware {
    var remote: MeetingAudioInput?
    var mic: MeetingAudioInput?
    func startRemote(bundleID: String, pid: Int32, output: MeetingAudioInput) throws { remote = output }
    func startMicrophone(output: MeetingAudioInput) throws { mic = output }
    func stopMicrophone() { mic = nil }
    func stopRemote() { remote = nil }
}
