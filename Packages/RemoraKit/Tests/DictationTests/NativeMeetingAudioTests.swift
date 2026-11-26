import AVFoundation
import Foundation
import Speech
import Testing
@testable import Dictation

struct NativeMeetingAudioTests {
    @Test func helperMustBelongToTheSelectedClientInstanceAndBundle() {
        let bundle = URL(fileURLWithPath: "/Applications/Meeting.app")
        let helper = bundle.appendingPathComponent("Contents/Frameworks/Helper.app/Contents/MacOS/Helper")
        let parents: [Int32: Int32] = [12: 11, 11: 10, 13: 20]
        func owned(_ pid: Int32, _ path: URL?) -> Bool {
            MeetingProcessOwnership.contains(pid: pid, executable: path, rootPID: 10,
                                            bundle: bundle, parent: { parents[$0] })
        }
        #expect(owned(10, nil))
        #expect(owned(12, helper))
        #expect(!owned(13, helper))
        #expect(!owned(12, nil))
        #expect(!owned(12, URL(fileURLWithPath: "/Applications/Meeting.app.backup/Contents/MacOS/Helper")))
    }

    @Test @MainActor func mutingStopsOnlyTheMicAndStopDeliversFinalSegmentsBeforeReturning() async throws {
        let hardware = FakeMeetingHardware()
        let final = TranscriberResult(text: "Final words", isFinal: true, startSeconds: 2, endSeconds: 3)
        let transcriber = FakeTranscriber(scripts: [.init(onInputEnd: [final]), .init(onInputEnd: [final])])
        let session = NativeMeetingAudioSession(hardware: hardware, transcriber: transcriber)
        var segments: [MeetingAudioSegment] = []
        try await session.start(bundleID: "example.meeting", pid: 10, locale: .en, micAllowed: false,
                                onSegment: { segments.append($0) }, onInterrupted: { Issue.record("Unexpected interruption") })
        #expect(hardware.remoteActive)
        #expect(!hardware.micActive)
        session.setMicAllowed(true)
        #expect(hardware.micActive)
        session.setMicAllowed(false)
        #expect(!hardware.micActive)
        #expect(hardware.remoteActive)
        await session.stop()
        #expect(!hardware.remoteActive)
        #expect(Set(segments.map(\.source)) == [.microphone, .remote])
        #expect(segments.allSatisfy { $0.startSeconds == 2 && $0.endSeconds == 3 && $0.text == "Final words" })
    }

    @Test func speechAfterASilentDeviceGapKeepsItsMeetingTime() async throws {
        let origin = AVAudioTime.hostTime(forSeconds: 10)
        let input = MeetingAudioInput(format: format16k, origin: origin) { Issue.record("Unexpected interruption") }
        input.open(at: origin)
        let converter = try MeetingPCMConverter(input: format16k, output: input)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format16k, frameCapacity: 160))
        buffer.frameLength = 160
        buffer.int16ChannelData![0].update(repeating: 0, count: 160)
        converter.append(buffer, hostTime: origin)
        converter.append(buffer, hostTime: origin + AVAudioTime.hostTime(forSeconds: 3))
        input.close()
        var times: [Int64] = []
        for await chunk in input.stream { times.append(chunk.bufferStartTime!.value) }
        #expect(times == [0, 48_000])
    }

    @Test func overloadedAudioPipeStopsOnceAndKeepsOnlyItsBoundedPrefix() async {
        let failures = Locked(0)
        let input = MeetingAudioInput(format: format16k, origin: 0) { failures.withLock { $0 += 1 } }
        input.open(at: 0)
        for i in 0..<100 { input.append(chunk(i), hostTime: 0) }
        var received: [Int64] = []
        for await item in input.stream { received.append(item.bufferStartTime!.value) }
        #expect(received == Array(0..<32))
        #expect(failures.withLock { $0 } == 1)
    }

    @Test func mutedTapDropsLateCallbacksAndSamplesFromBeforeUnmute() throws {
        let gate = MeetingMicrophoneGate(openedAt: 20)
        var accepted: [Int] = []
        gate.withPermission(hostTime: 19) { accepted.append(1) }
        gate.withPermission(hostTime: 20) { accepted.append(2) }
        gate.close()
        gate.withPermission(hostTime: 21) { accepted.append(3) }
        #expect(accepted == [2])
    }

    @Test(arguments: [MeetingAudioSource.remote, .microphone]) @MainActor
    func eitherAudioInterruptionClosesBothDevicesAndNotifiesOnce(source: MeetingAudioSource) async throws {
        let hardware = FakeMeetingHardware()
        let session = NativeMeetingAudioSession(hardware: hardware, transcriber: FakeTranscriber())
        var interruptions = 0
        try await session.start(bundleID: "example.meeting", pid: 10, locale: .en, micAllowed: true,
                                onSegment: { _ in }, onInterrupted: { interruptions += 1 })
        let input = try #require(source == .remote ? hardware.remote : hardware.mic)
        input.interrupt()
        input.interrupt()
        #expect(await eventually { @MainActor in !hardware.remoteActive })
        #expect(!hardware.micActive)
        #expect(interruptions == 1)
        #expect(session.interruptedSource == source)
        await session.stop()
    }

    @Test @MainActor func setupAudioAndLatePreverificationBuffersNeverEnterTheAnalyzer() async throws {
        let hardware = FakeMeetingHardware()
        let transcriber = FakeTranscriber()
        let session = NativeMeetingAudioSession(hardware: hardware, transcriber: transcriber)
        var beforeVerification: UInt64 = 0
        try await session.start(bundleID: "example.meeting", pid: 10, locale: .en, micAllowed: true,
            verify: {
                beforeVerification = mach_absolute_time()
                hardware.remote?.append(chunk(1), hostTime: beforeVerification)
                #expect(!hardware.micActive)
                session.setMicAllowed(false)
                return true
            }, onSegment: { _ in }, onInterrupted: {})
        #expect(!hardware.micActive)
        hardware.remote?.append(chunk(2), hostTime: beforeVerification)
        hardware.remote?.append(chunk(3), hostTime: mach_absolute_time())
        await session.stop()
        #expect(transcriber.sessions.flatMap(\.chunkTags) == [3])
    }

    @Test @MainActor func failedOrCancelledVerificationNeverStartsTheMic() async throws {
        for cancel in [false, true] {
            let hardware = FakeMeetingHardware()
            let session = NativeMeetingAudioSession(hardware: hardware, transcriber: FakeTranscriber())
            await #expect(throws: CancellationError.self) {
                try await session.start(bundleID: "example.meeting", pid: 10, locale: .en, micAllowed: true,
                    verify: {
                        if cancel { session.cancel() }
                        return cancel
                    }, onSegment: { _ in Issue.record("Discarded result was delivered") }, onInterrupted: {})
            }
            #expect(!hardware.micActive)
            #expect(!hardware.remoteActive)
        }
    }

    @Test @MainActor func cancellationDiscardsPendingResultsAndCannotRestartTheMic() async throws {
        let hardware = FakeMeetingHardware()
        let transcriber = FakeTranscriber(scripts: [.init(onInputEnd: [
            .init(text: "Pending", isFinal: true, startSeconds: 0, endSeconds: 1)
        ])])
        let session = NativeMeetingAudioSession(hardware: hardware, transcriber: transcriber)
        try await session.start(bundleID: "example.meeting", pid: 10, locale: .en, micAllowed: true,
                                onSegment: { _ in Issue.record("Discarded segment was delivered") }, onInterrupted: {})
        session.cancel()
        session.setMicAllowed(true)
        await session.stop()
        #expect(!hardware.micActive)
        #expect(!hardware.remoteActive)
    }
}

@MainActor private final class FakeMeetingHardware: MeetingAudioHardware {
    var remote: MeetingAudioInput?
    var mic: MeetingAudioInput?
    var remoteActive = false
    var micActive = false

    func startRemote(bundleID: String, pid: Int32, output: MeetingAudioInput) throws { remote = output; remoteActive = true }
    func startMicrophone(output: MeetingAudioInput) throws { mic = output; micActive = true }
    func stopMicrophone() { micActive = false }
    func stopRemote() { remoteActive = false }
}
