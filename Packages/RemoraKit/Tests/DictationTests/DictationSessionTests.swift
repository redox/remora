import AVFoundation
import Speech
import Testing
@testable import Dictation

/// Every test drives fakes only: no microphone, no speech framework analysis, no audio on disk.
struct DictationSessionTests {
    private func make(_ scripts: [TranscriberScript], formats: [DictationLocale: AVAudioFormat] = [:],
                      locale: DictationLocale = .fr, limits: SessionLimits = .init(),
                      audio: FakeAudioCapture = FakeAudioCapture())
        -> (DictationSession, FakeAudioCapture, FakeTranscriber, EventLog) {
        let transcriber = FakeTranscriber(scripts: scripts, formats: formats)
        let session = DictationSession(audio: audio, transcriber: transcriber, locale: locale, limits: limits)
        return (session, audio, transcriber, EventLog(session.events))
    }

    /// The English "Hello." was shown, then a locale switch emitted an empty transcript to clear the HUD.
    private func clearedAfterHello(_ events: [DictationSession.Event]) -> Bool {
        guard let hello = events.firstIndex(of: .transcript(.init(finalized: "Hello.", volatile: ""))),
              let cleared = events.lastIndex(of: .transcript(.init())) else { return false }
        return cleared > hello
    }

    @Test func streamsTranscriptEvents() async throws {
        let (session, audio, _, log) = make([.init(afterChunks: [1: [.final("Bonjour.")], 2: [.volatile("ça")]])])
        try await session.start()
        #expect(await eventually { log.contains(.listening(.fr)) })
        await audio.sendChunk(0)
        await audio.sendChunk(1)
        #expect(await eventually { log.contains(.transcript(.init(finalized: "Bonjour.", volatile: "ça"))) })
        #expect(log.contains(.transcript(.init(finalized: "Bonjour.", volatile: ""))))
        await session.cancel()
    }

    @Test func forwardsLevels() async throws {
        let (session, audio, _, log) = make([.init()])
        try await session.start()
        await audio.send(.level(0.5))
        #expect(await eventually { log.contains(.level(0.5)) })
        await session.cancel()
    }

    @Test func finishReturnsFinalizedText() async throws {
        let (session, audio, transcriber, log) = make([
            .init(afterChunks: [1: [.final("Bonjour.")]], onInputEnd: [.final("Ça va ?")]),
        ])
        try await session.start()
        await audio.sendChunk(0)
        #expect(await eventually { log.contains(.transcript(.init(finalized: "Bonjour.", volatile: ""))) })
        #expect(await session.finish() == "Bonjour. Ça va ?")
        #expect(await audio.stopCalls == 1)
        #expect(transcriber.sessions[0].inputEnded)
        #expect(await eventually { log.isEnded })
    }

    @Test func finishForwardsChunksStillQueuedWhenAudioStops() async throws {
        let (session, audio, transcriber, _) = make([.init(onInputEnd: [.final("Done.")])])
        try await session.start()
        for i in 0..<5 { await audio.sendChunk(i) }
        #expect(await session.finish() == "Done.")
        #expect(transcriber.sessions[0].chunkTags == [0, 1, 2, 3, 4])
    }

    @Test func finishCanReturnABoundedWAVAlongsideTheLocalTranscript() async throws {
        let (session, audio, _, _) = make([.init(onInputEnd: [.final("Bonjour.")])])
        try await session.start()
        await audio.sendChunk(0)
        await audio.sendChunk(1)

        let result = await session.finish(retainAudio: true)
        let wav = try #require(result.wav)
        #expect(result.text == "Bonjour.")
        #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: wav.dropFirst(8).prefix(4), as: UTF8.self) == "WAVE")
        #expect(wav.count == 684)
        #expect(await session.bufferedChunkCount == 0)
    }

    @Test func transcriptionWAVResamplesTheAnalyzersAudio() throws {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format48k, frameCapacity: 4800))
        buffer.frameLength = 4800
        let samples = try #require(buffer.int16ChannelData)
        samples[0].update(repeating: 1_000, count: 4800)
        let chunks = [AnalyzerInput(buffer: buffer), AnalyzerInput(buffer: buffer)]

        let wav = try #require(DictationWAV.encode(chunks, input: format48k))
        #expect(wav.count == 6444)  // two tenths of a second of 16 kHz mono PCM and the WAV header
        #expect(wav.dropFirst(44).contains { $0 != 0 })
    }

    @Test func cancelledDictationNeverReturnsAudio() async throws {
        let (session, audio, _, _) = make([.init()])
        try await session.start()
        await audio.sendChunk(0)
        await session.cancel()

        let result = await session.finish(retainAudio: true)
        #expect(result.wav == nil)
        #expect(result.text.isEmpty)
    }

    @Test func finishUsesVolatileTailWhenFinalizationTimesOut() async throws {
        let (session, audio, transcriber, log) = make(
            [.init(afterChunks: [1: [.final("Bonjour.")], 2: [.volatile("ça va")]], hangOnInputEnd: true)],
            limits: .init(finalizeTimeout: .milliseconds(50)))
        try await session.start()
        await audio.sendChunk(0)
        await audio.sendChunk(1)
        #expect(await eventually { log.contains(.transcript(.init(finalized: "Bonjour.", volatile: "ça va"))) })
        let started = ContinuousClock.now
        #expect(await session.finish() == "Bonjour. ça va")
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(await eventually { transcriber.sessions[0].cancelled })
        #expect(await audio.stopCalls == 1)
    }

    @Test(arguments: ["finish", "cancel", "transcriberError", "limit", "interrupted"])
    func audioStopsOnEveryExitPath(_ path: String) async throws {
        let limits = SessionLimits(maxDuration: path == "limit" ? .milliseconds(50) : .seconds(300))
        let script = TranscriberScript(afterChunks: [1: [.final("Hello.")]],
                                       failAfterChunk: path == "transcriberError" ? 1 : nil)
        let (session, audio, _, log) = make([script], limits: limits)
        try await session.start()
        switch path {
        case "finish":
            await audio.sendChunk(0)
            _ = await session.finish()
        case "cancel":
            await audio.sendChunk(0)
            await session.cancel()
        case "transcriberError":
            await audio.sendChunk(0)
            #expect(await eventually { log.all.contains { if case .failed(.transcriber) = $0 { true } else { false } } })
            #expect(await eventually { await audio.stopCalls == 1 })
            _ = await session.finish()
        case "limit":
            #expect(await eventually { log.contains(.limitReached) })
            #expect(await eventually { await audio.stopCalls == 1 })
            _ = await session.finish()
        case "interrupted":
            await audio.send(.interrupted)
            #expect(await eventually { log.contains(.interrupted) })
            #expect(await eventually { await audio.stopCalls == 1 })
            _ = await session.finish()
        default:
            Issue.record("unknown path \(path)")
        }
        #expect(await audio.startCalls == 1)
        #expect(await audio.stopCalls == 1)
        // A late cancel after the session ended never stops the audio a second time.
        await session.cancel()
        #expect(await audio.stopCalls == 1)
    }

    @Test func interruptedKeepsTextSoFar() async throws {
        let (session, audio, _, log) = make([.init(afterChunks: [1: [.final("Hello there.")]])], locale: .en)
        try await session.start()
        await audio.sendChunk(0)
        #expect(await eventually { log.contains(.transcript(.init(finalized: "Hello there.", volatile: ""))) })
        await audio.send(.interrupted)
        #expect(await eventually { log.contains(.interrupted) })
        #expect(await session.finish() == "Hello there.")
    }

    @Test func audioStreamEndingUnexpectedlyCountsAsInterruption() async throws {
        let (session, audio, _, log) = make([.init(afterChunks: [1: [.final("Hi.")]])])
        try await session.start()
        await audio.sendChunk(0)
        #expect(await eventually { log.contains(.transcript(.init(finalized: "Hi.", volatile: ""))) })
        await audio.stop()  // the device vanished: the stream ends without the session asking
        #expect(await eventually { log.contains(.interrupted) })
        #expect(await session.finish() == "Hi.")
    }

    @Test func limitReachedAfterMaxDuration() async throws {
        let (session, audio, transcriber, log) = make(
            [.init(afterChunks: [1: [.final("Un.")]])], limits: .init(maxDuration: .milliseconds(50)))
        try await session.start()
        await audio.sendChunk(0)
        #expect(await eventually { log.contains(.limitReached) })
        #expect(await eventually { transcriber.sessions[0].inputEnded })
        await audio.sendChunk(1)  // after the cap: never forwarded
        #expect(await session.finish() == "Un.")
        #expect(transcriber.sessions[0].chunkTags == [0])
        #expect(log.all.filter { $0 == .limitReached }.count == 1)
    }

    @Test func cancelReturnsNoTextAndDropsBuffers() async throws {
        let (session, audio, transcriber, log) = make([.init(afterChunks: [2: [.final("Secret.")]])])
        try await session.start()
        await audio.sendChunk(0)
        await audio.sendChunk(1)
        #expect(await eventually { log.contains(.transcript(.init(finalized: "Secret.", volatile: ""))) })
        #expect(await session.bufferedChunkCount == 2)
        await session.cancel()
        #expect(await session.bufferedChunkCount == 0)
        #expect(await session.currentText == "")
        #expect(await eventually { transcriber.sessions[0].cancelled })
        #expect(await eventually { log.isEnded })
        #expect(await session.finish() == "")
        #expect(await audio.stopCalls == 1)
    }

    @Test func finishDropsBuffersAndText() async throws {
        let (session, audio, _, _) = make([.init(afterChunks: [1: [.final("Mot.")]])])
        try await session.start()
        await audio.sendChunk(0)
        #expect(await session.finish() == "Mot.")
        #expect(await session.bufferedChunkCount == 0)
        #expect(await session.currentText == "")
        #expect(await session.finish() == "")
        #expect(await audio.stopCalls == 1)
    }

    @Test func switchLocaleReplaysBufferedAudio() async throws {
        let (session, audio, transcriber, log) = make([
            .init(afterChunks: [1: [.final("Hello.")]]),
            .init(afterChunks: [3: [.final("Bonjour.")]], onInputEnd: [.final("Ça va ?")]),
        ], locale: .en)
        try await session.start()
        for i in 0..<3 { await audio.sendChunk(i) }
        #expect(await eventually { transcriber.sessions.first?.chunkTags.count == 3 })
        #expect(await eventually { log.contains(.transcript(.init(finalized: "Hello.", volatile: ""))) })
        try await session.switchLocale(.fr)
        #expect(await session.locale == .fr)
        #expect(await eventually { log.contains(.listening(.fr)) })
        #expect(clearedAfterHello(log.all))
        #expect(await eventually { transcriber.sessions.count == 2 && transcriber.sessions[1].chunkTags.count == 3 })
        #expect(transcriber.sessions[1].locale == .fr)
        #expect(transcriber.sessions[1].chunkTags == [0, 1, 2])
        #expect(await eventually { transcriber.sessions[0].cancelled })
        #expect(await audio.startCalls == 1)
        #expect(await audio.stopCalls == 0)
        // Live audio continues into the new transcription.
        await audio.sendChunk(3)
        #expect(await eventually { transcriber.sessions[1].chunkTags == [0, 1, 2, 3] })
        // The accumulator was reset: the English text is gone.
        #expect(await session.finish() == "Bonjour. Ça va ?")
        #expect(await audio.stopCalls == 1)
    }

    @Test func switchLocaleWithDifferentFormatRestartsCapture() async throws {
        let (session, audio, transcriber, log) = make(
            [.init(afterChunks: [1: [.final("Hello.")]]), .init(onInputEnd: [.final("Salut.")])],
            formats: [.fr: format48k], locale: .en)
        try await session.start()
        for i in 0..<3 { await audio.sendChunk(i) }
        #expect(await eventually { transcriber.sessions.first?.chunkTags.count == 3 })
        #expect(await eventually { log.contains(.transcript(.init(finalized: "Hello.", volatile: ""))) })
        try await session.switchLocale(.fr)
        #expect(await eventually { log.contains(.listening(.fr)) })
        #expect(clearedAfterHello(log.all))
        #expect(await audio.startCalls == 2)
        #expect(await audio.stopCalls == 1)
        #expect(await audio.formats.last == format48k)
        #expect(transcriber.sessions.count == 2)
        #expect(transcriber.sessions[1].format == format48k)
        #expect(transcriber.sessions[1].chunkTags.isEmpty)
        #expect(await session.bufferedChunkCount == 0)
        await audio.sendChunk(10)
        #expect(await eventually { transcriber.sessions[1].chunkTags == [10] })
        #expect(await session.finish() == "Salut.")
        #expect(await audio.stopCalls == 2)
    }

    /// `cancel()`/`finish()` landing while a format-changing switch waits for the old capture to stop must
    /// win: the switch never restarts the analyzer or the microphone after the session ended.
    @Test(arguments: ["cancel", "finish"])
    func endingDuringFormatChangingSwitchNeverRestartsAudio(_ ending: String) async throws {
        let (session, audio, transcriber, log) = make(
            [.init(afterChunks: [1: [.final("Hello.")]])], formats: [.fr: format48k], locale: .en,
            limits: .init(finalizeTimeout: .milliseconds(100)))
        try await session.start()
        await audio.sendChunk(0)
        #expect(await eventually { transcriber.sessions.first?.chunkTags.count == 1 })
        await audio.gateStop()
        let switching = Task { try await session.switchLocale(.fr) }
        #expect(await eventually { await audio.stopCalls == 1 })  // the switch is suspended in stop()
        let ending = Task {
            if ending == "cancel" { await session.cancel(); return "" }
            return await session.finish()
        }
        #expect(await eventually { await !session.isRunning })
        await audio.releaseStop()
        try? await switching.value
        _ = await ending.value
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await audio.startCalls == 1)
        #expect(await audio.stopCalls == 1)
        #expect(transcriber.sessions.count == 1)
        #expect(!log.all.contains(.listening(.fr)))
        #expect(await eventually { log.isEnded })
    }

    @Test func switchToSameLocaleIsANoOp() async throws {
        let (session, audio, transcriber, _) = make([.init()])
        try await session.start()
        try await session.switchLocale(.fr)
        #expect(transcriber.sessions.count == 1)
        #expect(await audio.startCalls == 1)
        await session.cancel()
    }

    @Test func durationLimitDuringALocaleSwitchNeverRestartsTheMicrophone() async throws {
        let audio = FakeAudioCapture()
        let transcriber = FakeTranscriber(scripts: [.init()], formats: [.fr: format48k])
        let (ticks, clock) = AsyncStream<Void>.makeStream()
        let session = DictationSession(audio: audio, transcriber: transcriber, locale: .en,
                                       waitForLimit: { _ in
            for await _ in ticks { return }
            throw CancellationError()
        })
        let log = EventLog(session.events)
        try await session.start()
        await audio.gateStop()
        let switching = Task { try await session.switchLocale(.fr) }
        #expect(await eventually { await audio.stopCalls == 1 })
        clock.yield(())
        #expect(await eventually { log.contains(.limitReached) })
        await audio.releaseStop()
        try await switching.value
        #expect(await audio.startCalls == 1)
        #expect(transcriber.sessions.count == 1)
        #expect(!log.contains(.listening(.fr)))
        _ = await session.finish()
        clock.finish()
    }

    @Test func secondStartThrows() async throws {
        let (session, audio, _, _) = make([.init()])
        try await session.start()
        await #expect(throws: DictationError.alreadyRunning) { try await session.start() }
        #expect(await audio.startCalls == 1)
        await session.cancel()
        await #expect(throws: DictationError.alreadyRunning) { try await session.start() }
    }

    @Test func startFailureStopsAudioAndCancelsTranscription() async throws {
        let audio = FakeAudioCapture(startError: .noInputDevice)
        let (session, _, transcriber, log) = make([.init()], audio: audio)
        await #expect(throws: DictationError.noInputDevice) { try await session.start() }
        #expect(await audio.startCalls == 1)
        #expect(await audio.stopCalls == 1)
        #expect(await eventually { transcriber.sessions.allSatisfy { $0.cancelled || $0.inputEnded } })
        #expect(await eventually { log.isEnded })
        #expect(!log.all.contains(.listening(.fr)))
    }

    @Test func cancelBeforeStartNeverTouchesAudio() async throws {
        let (session, audio, _, log) = make([.init()])
        await session.cancel()
        #expect(await audio.startCalls == 0)
        #expect(await audio.stopCalls == 0)
        #expect(await eventually { log.isEnded })
    }

    /// A cancel landing while `audio.start` is still running: the session stops the audio again once
    /// the start returns (`stop()` is idempotent), so an engine that started after the first stop
    /// never keeps the microphone on.
    @Test(arguments: ["cancel", "finish"])
    func stopRacingStartStopsAudioAgain(_ ending: String) async throws {
        let audio = FakeAudioCapture()
        await audio.gateStart()
        let (session, _, _, log) = make([.init()], audio: audio)
        let starting = Task { try await session.start() }
        #expect(await eventually { await audio.startCalls == 1 })  // suspended in audio.start
        if ending == "cancel" { await session.cancel() } else { _ = await session.finish() }
        #expect(await audio.stopCalls == 1)
        await audio.releaseStart()
        try? await starting.value
        #expect(await eventually { await audio.stopCalls == 2 })
        #expect(await audio.startCalls == 1)
        #expect(!log.all.contains(.listening(.fr)))
        #expect(await eventually { log.isEnded })
    }
}
