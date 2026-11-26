import AppKit
import AVFoundation
import Capture
import Dictation
import MeetingImport
import Observation
import Storage

@MainActor @Observable
final class MeetingRecordingController {
    private struct Preferences: Codable {
        static let key = "meetingRecording.settings"
        var enabled = false
        var locale = DictationLocale.systemDefault()
    }

    @MainActor
    private final class Recording {
        let audio = NativeMeetingAudioSession()
        let start = Date()
        let generation: Int
        let transcriptionKey: String?
        var meeting: VerifiedMeeting
        var transcript = MeetingTranscript()
        var observer: AXNotificationObserver?
        var lastVerified: TimeInterval = 0
        var observingCall = false
        var finishing = false
        var finishTask: Task<Void, Never>?
        var verificationDeadline: Task<Void, Never>?

        init(_ meeting: VerifiedMeeting, generation: Int, transcriptionKey: String?) {
            self.transcriptionKey = transcriptionKey
            self.meeting = meeting
            self.generation = generation
        }
    }

    private let openAITranscription = OpenAITranscription()
    private unowned let env: AppEnvironment
    private var preferences: Preferences
    private var active: Recording?
    private(set) var status: String?
    private static let idleStatus = "Waiting for a joined Meet, Zoom or Teams call."
    private var waitingStatus = idleStatus
    var displayStatus: String {
        if env.isPaused { return "Meeting recording is paused." }
        if !env.permissions.accessibilityGranted { return "Meeting recording needs Accessibility permission." }
        if env.permissions.microphone != .granted { return "Meeting recording needs microphone permission." }
        return status ?? waitingStatus
    }
    private var previous: MeetingContinuity?
    private var starts = MeetingStartPolicy()
    private var revision = 0
    private var checking = false
    private var needsRecheck = false
    private var delayedCheck: Task<Void, Never>?
    private var lastCheck = ContinuousClock.now - .seconds(5)
    private var deviceObservers: [NSKeyValueObservation] = []
    private var periodicTask: Task<Void, Never>?

    init(env: AppEnvironment) {
        self.env = env
        preferences = (try? SettingsStore(env.db).value(Preferences.self, forKey: Preferences.key)) ?? Preferences()
    }

    var enabled: Bool { preferences.enabled }
    var locale: DictationLocale { preferences.locale }
    var busy: Bool { active != nil }
    var canStop: Bool {
        if let active { return !active.finishing || starts.retryingID == active.meeting.id }
        return starts.retryingID != nil && starts.retryingID == previous?.id
    }
    private(set) var recordingClientName: String?

    func configure(enabled: Bool, locale: DictationLocale) {
        let updated = Preferences(enabled: enabled, locale: locale)
        do {
            try SettingsStore(env.db).setValue(updated, forKey: Preferences.key)
            preferences = updated
            if !enabled {
                discard()
                status = nil
            }
            watch()
        } catch {
            status = "Could not save meeting settings."
        }
    }

    func watch() {
        periodicTask?.cancel()
        periodicTask = nil
        delayedCheck?.cancel()
        delayedCheck = nil
        deviceObservers.removeAll()
        guard enabled else { return }
        for type in [AVMediaType.audio, .video] {
            guard let device = AVCaptureDevice.default(for: type) else { continue }
            deviceObservers.append(device.observe(\.isInUseByAnotherApplication, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.check() }
            })
        }
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.check()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }

    private var allowed: Bool {
        enabled && env.meetingSessionAvailable && !env.isDeletingAll
            && (try? SettingsStore(env.db).isPaused(now: .now)) == false
    }

    func transcriptionKeyChanged() {
        // A provider is chosen before the first sample. Adding a key during a local call keeps that call local.
        if active?.transcriptionKey != nil { discard() }
        check()
    }

    func policyChanged() {
        if let active, !SnapshotPolicy.current(env.db).shouldCapture(active.meeting.context) {
            discard()
        } else {
            revision += 1
            check()
        }
    }

    func discard() {
        revision += 1
        env.meetingSources.cancelPendingRecordingNotes()
        if let active {
            starts.suppress(active.meeting.id)
            active.verificationDeadline?.cancel()
            active.finishTask?.cancel()
            active.audio.cancel()
            recordingClientName = nil
            self.active = nil
            status = "Meeting recording discarded."
        } else if let id = starts.retryingID {
            starts.suppress(id)
        }
    }

    func check() {
        guard enabled else { return }
        guard allowed else { discard(); return }
        guard env.permissions.accessibilityGranted, env.permissions.microphone == .granted else {
            interrupt(reason: "Meeting recording lost access to Accessibility or the microphone.")
            return
        }
        guard active?.finishing != true else { return }
        if checking { needsRecheck = true; return }
        let now = ContinuousClock.now
        let next = lastCheck + .milliseconds(250)
        if now < next {
            // Coalesce an event burst without dropping the last mute or window change.
            if delayedCheck == nil {
                delayedCheck = Task { [weak self] in
                    do { try await Task.sleep(until: next, clock: .continuous) } catch { return }
                    self?.delayedCheck = nil
                    self?.check()
                }
            }
            return
        }
        lastCheck = now
        checking = true
        let expected = revision
        Task {
            defer {
                checking = false
                if needsRecheck {
                    needsRecheck = false
                    check()
                }
            }
            let policy = SnapshotPolicy.current(env.db)
            guard !policy.deniesEverything else { discard(); return }
            if let active, !policy.shouldCapture(active.meeting.context) { discard(); return }
            let observationStart = active?.audio.elapsedSeconds ?? 0
            let result = await MeetingDetector().detect(policy: policy, previous: previous)
            guard revision == expected, !Task.isCancelled else { return }
            guard allowed else { discard(); return }
            switch result {
            case .joined(let meeting):
                let currentPolicy = SnapshotPolicy.current(env.db)
                guard currentPolicy.shouldCapture(meeting.context) else { discard(); return }
                if let active {
                    guard active.meeting.id == meeting.id else {
                        interrupt(reason: "The active call changed.")
                        return
                    }
                    switch MeetingSourceCheck.evaluate(original: active.meeting.context, current: meeting.context, policy: currentPolicy) {
                    case .denied: discard(); return
                    case .changed: interrupt(reason: "The call window changed."); return
                    case .verified: break
                    }
                    if active.meeting.micAllowed && !meeting.micAllowed {
                        active.transcript.withholdMicrophone(after: active.lastVerified, until: active.audio.elapsedSeconds)
                    }
                    if active.observingCall {
                        active.audio.confirmVerified(through: observationStart, micAllowed: meeting.micAllowed)
                    }
                    active.lastVerified = max(active.lastVerified, observationStart)
                    renewDeadline(active)
                    active.audio.setMicAllowed(active.observingCall && meeting.micAllowed)
                    guard !active.finishing else { return }
                    if active.observingCall, recordingClientName == nil {
                        recordingClientName = meeting.client.displayName
                        status = "Recording \(meeting.client.displayName)"
                    }
                    for caption in meeting.captions where !active.meeting.captions.contains(caption) {
                        if let speaker = caption.speaker {
                            active.transcript.captions.observe(text: caption.text, speaker: speaker, at: active.audio.elapsedSeconds)
                        }
                    }
                    active.meeting = meeting
                } else if starts.mayStart(meeting.id) {
                    begin(meeting)
                }
                previous = meeting.continuity
            case .left, .noVisibleCall:
                let confirmed = result == .left
                waitingStatus = Self.idleStatus
                if let active {
                    finish(interrupted: !confirmed, through: active.lastVerified,
                           reason: confirmed ? nil : "The joined call is no longer visible.")
                } else {
                    status = nil
                }
                previous = starts.continuityAfterAbsence(previous, departureConfirmed: confirmed)
            case .unverifiable(let issue):
                waitingStatus = issue.message
                if active == nil { status = nil }
                interrupt(reason: issue.message)
            case .denied:
                waitingStatus = "Meeting recording is blocked by the capture rules."
                discard()
            }
        }
    }

    /// A timeout on the shared AX queue must also close the devices if no further result arrives.
    private func renewDeadline(_ recording: Recording) {
        recording.verificationDeadline?.cancel()
        recording.verificationDeadline = Task { [weak self, weak recording] in
            let deadline = ContinuousClock.now + .seconds(8)
            do {
                // Closing the tab can erase the evidence of a joined call. Advance the verified
                // audio boundary while that evidence still exists, even when the UI is quiet.
                try await Task.sleep(for: .milliseconds(500))
                if let self, let recording, active === recording, recording.observingCall { check() }
                try await Task.sleep(until: deadline, clock: .continuous)
            } catch { return }
            guard let self, let recording, active === recording else { return }
            interrupt(reason: "Meeting recording timed out while verifying the call.")
        }
    }

    func stop() {
        guard canStop, let id = active?.meeting.id ?? starts.retryingID else { return }
        starts.suppress(id)
        if let active, !active.finishing {
            finish(interrupted: false, verifyTail: active.transcriptionKey != nil && active.observingCall)
        } else {
            status = "Meeting recording stopped."
        }
    }

    func interrupt(reason: String) {
        guard let active, !active.finishing else { return }
        starts.retryAfterInterruption(active.meeting.id)
        finish(interrupted: true, through: active.lastVerified, reason: reason)
    }

    private func begin(_ meeting: VerifiedMeeting) {
        guard let generation = try? DataGeneration.current(env.db) else { return }
        let key: String?
        do {
            key = try TranscriptionKeychain.load()
        } catch {
            status = "Could not read the transcription key from Keychain."
            return
        }
        let recording = Recording(meeting, generation: generation, transcriptionKey: key)
        active = recording
        status = "Starting \(meeting.client.displayName) recording…"
        let language = locale
        Task { [self, recording] in
            do {
                if key == nil, await SystemSpeechAssets().status(language) != .installed {
                    if active === recording {
                        active = nil
                        status = "Install the meeting speech model in Meeting sources."
                    }
                    return
                }
                guard self.active === recording, !recording.finishing, allowed else { return }
                // A permission prompt can keep start suspended. Reverify the mic before admitting its samples.
                try await recording.audio.start(bundleID: meeting.bundleID, pid: meeting.pid, locale: language,
                    micAllowed: false, cloudTranscribe: cloudTranscriber(for: recording), verify: { [weak self, weak recording] in
                        guard let self, let recording else { return false }
                        return await self.verifyStart(recording)
                    }, onSegment: { [weak self, weak recording] segment in
                        guard let self, let recording, self.active === recording else { return }
                        recording.transcript.append(text: segment.text, start: segment.startSeconds,
                                                    end: segment.endSeconds, microphone: segment.source == .microphone)
                    }, onInterrupted: { [weak self, weak recording] in
                        guard let self, let recording, self.active === recording else { return }
                        let reason: String
                        switch recording.audio.interruptedSource {
                        case .microphone: reason = "The microphone input was interrupted."
                        case .remote: reason = "The meeting app’s audio stream was interrupted."
                        case nil: reason = "Meeting transcription was interrupted."
                        }
                        self.interrupt(reason: reason)
                    })
                guard self.active === recording, !recording.finishing else { return }
                recording.audio.invalidateUnverifiedAudio()
                renewDeadline(recording)
                recording.observer = await AXNotificationObserver.observe(pid: meeting.pid,
                    notifications: [kAXValueChangedNotification, kAXTitleChangedNotification, kAXFocusedWindowChangedNotification]) { [weak self, weak recording] name in
                        guard let self, let recording, self.active === recording else { return }
                        self.revision += 1
                        if name != kAXValueChangedNotification {
                            recording.audio.invalidateUnverifiedAudio()
                        }
                        recording.audio.setMicAllowed(false)
                        self.check()
                    }
                guard active === recording, !recording.finishing else { return }
                recording.observingCall = true
                revision += 1
                lastCheck = .now - .seconds(5)
                check()
            } catch MeetingAudioStartupError.waitingForClientAudio {
                retryStartup(recording, message: "Waiting for \(meeting.client.displayName) to open its audio device.")
            } catch is CancellationError {
                retryStartup(recording, message: "Waiting to verify the joined call again.")
            } catch {
                retryStartup(recording, message: "Could not open meeting audio. Check system audio recording permission in System Settings.")
            }
        }
    }

    private func retryStartup(_ recording: Recording, message: String) {
        guard active === recording, !recording.finishing else { return }
        revision += 1
        recording.verificationDeadline?.cancel()
        recording.audio.cancel()
        starts.retryAfterInterruption(recording.meeting.id)
        active = nil
        recordingClientName = nil
        status = message
    }

    private func cloudTranscriber(for recording: Recording) -> MeetingCloudTranscribe? {
        guard let key = recording.transcriptionKey else { return nil }
        return { [weak self, weak recording] audio in
            guard let self, let recording, self.mayTranscribe(recording, key: key) else { throw CancellationError() }
            let text = try await self.openAITranscription.transcribe(audio, key: key)
            guard self.mayTranscribe(recording, key: key) else { throw CancellationError() }
            return text
        }
    }

    /// The audio session admits only intervals verified against this call, including the final drain after leaving.
    private func mayTranscribe(_ recording: Recording, key: String) -> Bool {
        !Task.isCancelled && active === recording && allowed
            && env.permissions.accessibilityGranted && env.permissions.microphone == .granted
            && AXIsProcessTrusted() && SystemMicrophonePermission().status() == .granted
            && (try? DataGeneration.current(env.db)) == recording.generation
            && SnapshotPolicy.current(env.db).shouldCapture(recording.meeting.context)
            && (try? TranscriptionKeychain.load()) == key
    }

    private func verifyStart(_ recording: Recording) async -> Bool {
        guard active === recording, !recording.finishing, allowed else { return false }
        let policy = SnapshotPolicy.current(env.db)
        let expected = revision
        let observed = await MeetingDetector().detect(policy: policy, previous: recording.meeting.continuity)
        guard revision == expected, active === recording, !recording.finishing, allowed,
              env.permissions.accessibilityGranted, env.permissions.microphone == .granted,
              case .joined(let current) = observed, current.id == recording.meeting.id,
              MeetingSourceCheck.evaluate(original: recording.meeting.context, current: current.context,
                                          policy: SnapshotPolicy.current(env.db)) == .verified else { return false }
        recording.meeting = current
        recording.lastVerified = recording.audio.elapsedSeconds
        return true
    }

    /// Recheck a manually stopped call after releasing both devices. An AX change during this read
    /// invalidates the tail. Leaving or losing the call can only use the last confirmed interval.
    private func confirmStoppedTail(_ recording: Recording, through cutoff: TimeInterval) async {
        let expected = revision
        let result = await MeetingDetector().detect(policy: SnapshotPolicy.current(env.db), previous: recording.meeting.continuity)
        guard expected == revision, active === recording, let key = recording.transcriptionKey,
              mayTranscribe(recording, key: key), case .joined(let current) = result,
              current.id == recording.meeting.id,
              MeetingSourceCheck.evaluate(original: recording.meeting.context, current: current.context,
                                          policy: SnapshotPolicy.current(env.db)) == .verified else { return }
        recording.audio.confirmVerified(through: cutoff, micAllowed: recording.meeting.micAllowed && current.micAllowed)
    }

    private func finish(interrupted: Bool, through cutoff: TimeInterval = .infinity, verifyTail: Bool = false,
                        reason: String? = nil) {
        guard let recording = active, !recording.finishing else { return }
        revision += 1
        recording.finishing = true
        recordingClientName = nil
        let stoppedAt = recording.audio.elapsedSeconds
        if verifyTail { recording.audio.closeForFinalVerification() } else { recording.observer = nil }
        recording.verificationDeadline?.cancel()
        status = "Finishing meeting transcript…"
        recording.finishTask = Task {
            defer { recording.finishTask = nil }
            if verifyTail {
                await confirmStoppedTail(recording, through: stoppedAt)
                recording.observer = nil
            }
            await recording.audio.stop()
            guard active === recording else { return }
            defer { if active === recording { active = nil } }
            guard allowed, SnapshotPolicy.current(env.db).shouldCapture(recording.meeting.context) else {
                status = "Meeting recording discarded."
                return
            }
            let interrupted = interrupted || recording.audio.transcriptionInterrupted
            let transcript = recording.transcript.rendered(through: cutoff)
            guard !transcript.isEmpty else {
                status = reason ?? (recording.audio.transcriptionInterrupted
                    ? "Meeting transcription was interrupted." : "No meeting speech was transcribed.")
                return
            }
            let meeting = recording.meeting
            do {
                try await env.meetingSources.saveRecording(client: meeting.client.displayName,
                    title: meeting.context.windowTitle ?? meeting.client.displayName, startedAt: recording.start,
                    transcript: transcript, interrupted: interrupted, context: meeting.context,
                    generation: recording.generation, llm: env.llm)
                if active === recording {
                    status = interrupted ? "Interrupted meeting transcript saved." : "Meeting transcript saved."
                }
            } catch {
                if active === recording { status = "Could not save the meeting transcript." }
            }
        }
    }
}
