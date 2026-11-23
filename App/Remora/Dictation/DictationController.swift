import AppKit
import Capture
import Carbon.HIToolbox
import Dictation
import Input
import LLM
import Observation
import os
import Rewrite
import Storage

/// Records a local draft for the writing popover. Insert transcript can use the configured
/// transcription and cleanup services. Drafting and editing use the reviewed text.
@MainActor @Observable
final class DictationController {
    enum Phase: Equatable { case idle, starting, listening, finishing, transcribing, cleaning }

    private(set) var phase: Phase = .idle
    private(set) var sessionLocale: DictationLocale?
    private(set) var settings: DictationSettings
    private(set) var hasTranscriptionKey = false
    private(set) var isRunning = false

    /// The run can hold a local draft even after the microphone has stopped.
    var isActive: Bool { run != nil }
    var isRecording: Bool { run != nil && run?.raw == nil }

    // MARK: Dependencies

    @ObservationIgnored private let rewrite: RewriteController
    @ObservationIgnored private let permissions: PermissionsMonitor
    @ObservationIgnored private let speechAssets: SpeechAssetModel
    @ObservationIgnored private let cleaner: DictationCleaner
    @ObservationIgnored private let db: AppDatabase
    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let windows: FrontmostWindowReader
    @ObservationIgnored private let isPaused: @MainActor () -> Bool
    @ObservationIgnored private let observesContextSwitches: @MainActor () -> Bool
    @ObservationIgnored private let openDictationSettings: @MainActor () -> Void
    @ObservationIgnored private let transcriber = SpeechAnalyzerTranscriber()
    @ObservationIgnored private let openAITranscription = OpenAITranscription()
    @ObservationIgnored private var observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []

    // MARK: State

    private var run: Run?
    @ObservationIgnored private var accessibilityGranted = false
    private var localeMemory: LocaleMemory
    private static let log = Logger(subsystem: "dev.remora", category: "dictation")

    @MainActor
    private final class Run {
        let locale: DictationLocale
        let appKey: String?
        let frontmostPID: pid_t?
        let field: FocusedField?
        var session: DictationSession?
        var work: Task<Void, Never>?
        var events: Task<Void, Never>?
        var cloudContext: ContextIdentity?
        var cloudInvalidated = false
        var cloudRequest: Task<String, any Error>?
        var started = false
        var finishRequested = false
        var finishing = false
        var notice: DictationNotice?
        var raw: String?
        var wav: Data?

        init(locale: DictationLocale, appKey: String?, frontmostPID: pid_t?, field: FocusedField?) {
            self.locale = locale
            self.appKey = appKey
            self.frontmostPID = frontmostPID
            self.field = field
        }
    }

    init(rewrite: RewriteController, permissions: PermissionsMonitor, speechAssets: SpeechAssetModel, llm: LLMService,
         db: AppDatabase, windows: FrontmostWindowReader, isPaused: @escaping @MainActor () -> Bool,
         observesContextSwitches: @escaping @MainActor () -> Bool,
         openDictationSettings: @escaping @MainActor () -> Void) {
        self.rewrite = rewrite
        self.permissions = permissions
        self.speechAssets = speechAssets
        self.cleaner = DictationCleaner(llm: llm)
        self.db = db
        let store = SettingsStore(db)
        self.store = store
        self.windows = windows
        self.isPaused = isPaused
        self.observesContextSwitches = observesContextSwitches
        self.openDictationSettings = openDictationSettings
        settings = Self.load(DictationSettings.self, DictationSettings.settingsKey, store) ?? DictationSettings()
        localeMemory = Self.load(LocaleMemory.self, LocaleMemory.settingsKey, store) ?? LocaleMemory()
        hasTranscriptionKey = (try? TranscriptionKeychain.load()) != nil
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String, _ store: SettingsStore) -> T? {
        do { return try store.value(type, forKey: key) } catch {
            log.error("dictation setting unreadable: \(key, privacy: .public)")
            return nil
        }
    }

    // MARK: - Lifecycle

    /// Accessibility granted. Recording is available when dictation is enabled.
    func start() {
        accessibilityGranted = true
        applyRunning()
    }

    /// Accessibility revoked: discard any recording.
    func stop() {
        accessibilityGranted = false
        applyRunning()
    }

    func update(_ s: DictationSettings) {
        guard s != settings else { return }
        settings = s
        do { try store.setValue(s, forKey: DictationSettings.settingsKey) } catch {
            Self.log.error("dictation settings not saved")
        }
        applyRunning()
    }

    func saveTranscriptionKey(_ key: String) -> String? {
        do { try TranscriptionKeychain.save(key) } catch { return "Could not save the key to Keychain." }
        invalidateCloudTranscription()
        hasTranscriptionKey = true
        return nil
    }

    func refreshTranscriptionKeyStatus() {
        let available = (try? TranscriptionKeychain.load()) != nil
        if hasTranscriptionKey, !available { invalidateCloudTranscription() }
        hasTranscriptionKey = available
    }

    func removeTranscriptionKey() -> String? {
        do { try TranscriptionKeychain.remove() } catch { return "Could not remove the key from Keychain." }
        invalidateCloudTranscription()
        hasTranscriptionKey = false
        return nil
    }

    /// A pause or context switch keeps the current dictation local, even if the user switches back.
    func invalidateCloudTranscription() {
        run?.cloudInvalidated = true
        run?.cloudContext = nil
        run?.wav = nil
        run?.cloudRequest?.cancel()
    }

    /// The menu-bar quick switch; nil = Automatic (per-app memory, then the default).
    func setPinned(_ l: DictationLocale?) {
        var s = settings
        s.pinnedLocale = l
        update(s)
    }

    /// How many apps have a remembered language. Only the count is ever shown.
    var rememberedLanguageCount: Int { localeMemory.entries.count }

    /// Settings › Dictation › Forget: clears the per-app language memory.
    func forgetRememberedLanguages() {
        localeMemory.forgetAll()
        do { try store.setValue(localeMemory, forKey: LocaleMemory.settingsKey) } catch {
            Self.log.error("dictation language memory not saved")
        }
    }

    private func applyRunning() {
        let should = accessibilityGranted && settings.enabled
        guard should != isRunning else { return }
        isRunning = should
        if should {
            observeSleepAndLock()
            Task { [speechAssets] in await speechAssets.refresh() }
        } else {
            cancelSession()
            for observer in observers { observer.center.removeObserver(observer.token) }
            observers.removeAll()
        }
    }

    private func observeSleepAndLock() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.rewrite.closeEditBar() }
            }
            observers.append((workspace, token))
        }
        let distributed = DistributedNotificationCenter.default()
        let token = distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rewrite.closeEditBar() }
        }
        observers.append((distributed, token))
    }

    // MARK: - Recording

    var preferredLocale: DictationLocale { chooseLocale(Self.frontmost().appKey) }

    func beginRecording(field: FocusedField?, locale: DictationLocale?) -> Bool {
        guard isRunning, !isRecording, !IsSecureEventInputEnabled() else { return false }
        cancelSession()
        let front = Self.frontmost()
        let recording = Run(locale: locale ?? chooseLocale(front.appKey), appKey: front.appKey,
                            frontmostPID: front.pid, field: field)
        run = recording
        phase = .starting
        recording.work = Task { [weak self] in await self?.startChecked(recording) }
        return true
    }

    func finishRecording() {
        guard let run, isRecording else { return }
        finish(run)
    }

    private func startChecked(_ r: Run) async {
        if Self.needsRefresh(speechAssets.state(r.locale), installInFlight: speechAssets.installInFlight(r.locale)) {
            await speechAssets.refresh()
        }
        permissions.refreshMicrophone()
        guard isCurrent(r) else { return }
        let conditions = StartConditions(
            enabled: settings.enabled, sessionActive: false,
            rewriteBusy: false,
            transcriberAvailable: speechAssets.transcriberAvailable, microphone: permissions.microphone,
            asset: speechAssets.state(r.locale))
        switch StartCheck.evaluate(conditions, locale: r.locale) {
        case .ignore:
            end(r, notice: nil)
        case .requestMicrophone:
            end(r, notice: .microphoneRequested)
            await permissions.requestMicrophone()
        case .refuse(let notice):
            Self.log.info("dictation refused: \(Self.kind(notice), privacy: .public)")
            Sounds.play(.error, enabled: soundsEnabled)
            end(r, notice: notice)
            if case .assetMissing(let l) = notice { Task { [speechAssets] in await speechAssets.install(l) } }
        case .start:
            await listen(r)
        }
    }

    private static func needsRefresh(_ state: AssetState, installInFlight: Bool) -> Bool {
        switch state {
        case .unknown: true
        case .installing: !installInFlight
        case .notInstalled, .installed, .unsupported, .failed: false
        }
    }

    private func listen(_ r: Run) async {
        // Released during the start checks: leave the microphone off.
        if r.finishRequested { return end(r, notice: .microphoneNotReady) }
        guard !IsSecureEventInputEnabled(), Self.frontmost().pid == r.frontmostPID else {
            return end(r, notice: nil)
        }
        sessionLocale = r.locale
        let session = DictationSession(audio: EngineAudioCapture(), transcriber: transcriber, locale: r.locale)
        r.session = session
        r.events = Task { [weak self] in
            for await event in session.events { self?.apply(event, r) }
        }
        if r.field != nil, hasTranscriptionKey {
            // Let the microphone start while Accessibility verifies the original context. An
            // early release or an observed switch during the check keeps the result local.
            Task { [weak self] in
                guard let self, let context = await self.transcriptionContext(r),
                      !r.cloudInvalidated, !r.finishing, !r.finishRequested else { return }
                r.cloudContext = context
            }
        }
        Self.log.info("dictation began locale=\(r.locale.rawValue, privacy: .public)")
        do {
            try await session.start()
        } catch {
            Self.log.error("dictation start failed: \(String(describing: type(of: error)), privacy: .public)")
            guard isCurrent(r) else { return }
            Sounds.play(.error, enabled: soundsEnabled)
            end(r, notice: .failed)
            return
        }
        guard isCurrent(r) else { return }
        r.started = true
        if r.finishRequested { finish(r) }
    }

    private func apply(_ event: DictationSession.Event, _ r: Run) {
        guard isCurrent(r) else { return }
        switch event {
        case .listening(let locale):
            guard !r.finishing, !r.finishRequested else { return }
            if phase == .starting { Sounds.dictationStart(enabled: soundsEnabled) }
            phase = .listening
            sessionLocale = locale
            rewrite.recordingIsReady(locale)
        case .transcript(let update): rewrite.showTranscript(update.text)
        case .level: break
        case .interrupted:
            r.notice = r.notice ?? .microphoneLost
            finish(r)
        case .limitReached:
            r.notice = r.notice ?? .limitReached
            finish(r)
        case .failed:
            r.notice = r.notice ?? .failed
            finish(r)
        }
    }

    private func finish(_ r: Run) {
        guard isCurrent(r), !r.finishing else { return }
        guard r.started, let session = r.session else {
            r.finishRequested = true
            return
        }
        r.finishing = true
        let retainAudio = r.cloudContext != nil && r.notice == nil
        phase = .finishing
        rewrite.finalizeTranscript()
        r.work = Task { [weak self] in
            let result = await session.finish(retainAudio: retainAudio)
            self?.finishDraft(r, result: result)
        }
    }

    private func finishDraft(_ r: Run, result: CompletedDictation) {
        guard isCurrent(r) else { return }
        if result.receivedAudio { Sounds.dictationStop(enabled: soundsEnabled) }
        guard let raw = EditVoiceRoute.settleFinal(result.text) else {
            return end(r, notice: r.notice ?? (result.receivedAudio ? .nothingHeard : .microphoneNotReady))
        }
        let locale = sessionLocale ?? r.locale
        remember(locale, for: r.appKey)
        r.raw = raw
        r.wav = result.wav
        r.session = nil
        r.events?.cancel()
        r.events = nil
        r.work = nil
        phase = .idle
        rewrite.showFinalTranscript(raw)
    }

    struct InsertionText {
        let text: String
        let locale: DictationLocale
        let notice: DictationNotice?
    }

    /// The preview is always local. Only an unchanged transcript committed for direct insertion
    /// can use its audio or the configured cleanup. A correction in the preview wins.
    func prepareInsertion(_ text: String, field: FocusedField?) async -> InsertionText? {
        guard let r = run, let raw = r.raw else {
            return InsertionText(text: text, locale: settings.defaultLocale, notice: nil)
        }
        let locale = sessionLocale ?? r.locale
        let route = await cleanupRoute(field: field, r)
        guard isCurrent(r), !Task.isCancelled else { return nil }
        guard route != .refuse, !IsSecureEventInputEnabled(), Self.frontmost().pid == r.frontmostPID else {
            end(r, notice: .secureField)
            return nil
        }
        guard text == raw else {
            end(r, notice: nil)
            return InsertionText(text: text, locale: locale, notice: nil)
        }

        let wav = r.wav
        r.wav = nil
        let cloudTranscript = await transcribeWithOpenAI(wav, r)
        guard isCurrent(r), !Task.isCancelled else { return nil }
        let updatedRoute = await cleanupRoute(field: field, r)
        guard isCurrent(r), !Task.isCancelled else { return nil }
        guard updatedRoute != .refuse, !IsSecureEventInputEnabled(), Self.frontmost().pid == r.frontmostPID else {
            end(r, notice: .secureField)
            return nil
        }

        phase = .cleaning
        let cleaned: CleanupOutcome
        do {
            cleaned = try await cleaner.process(raw: cloudTranscript ?? raw, locale: cloudTranscript == nil ? locale : nil,
                                                cleanupEnabled: settings.cleanupEnabled,
                                                cloudAllowed: route.cloudAllowed && updatedRoute.cloudAllowed)
        } catch {
            end(r, notice: nil)
            return nil
        }
        guard isCurrent(r), !Task.isCancelled else { return nil }
        let notice = r.notice ?? cleaned.notice
        end(r, notice: nil)
        return InsertionText(text: cleaned.text, locale: locale, notice: notice)
    }

    private func transcribeWithOpenAI(_ wav: Data?, _ r: Run) async -> String? {
        guard let wav, let start = r.cloudContext, let key = try? TranscriptionKeychain.load(),
              await transcriptionContext(r) == start, r.cloudContext == start else { return nil }
        phase = .transcribing
        let client = openAITranscription
        let request = Task { try await client.transcribe(wav, key: key) }
        r.cloudRequest = request
        let result = await request.result
        r.cloudRequest = nil
        guard r.cloudContext == start, await transcriptionContext(r) == start, r.cloudContext == start else { return nil }
        switch result {
        case .success(let text): return text
        case .failure:
            r.notice = .openAITranscriptionUnavailable
            return nil
        }
    }

    private func transcriptionContext(_ r: Run) async -> ContextIdentity? {
        guard isCurrent(r), !r.cloudInvalidated, observesContextSwitches(), !isPaused(),
              let sample = await windows.readContext(), sample.identity.pid == r.frontmostPID,
              SnapshotPolicy.current(db).shouldCapture(sample.context), let handle = r.field?.handle else { return nil }
        let focused = await Task.detached(priority: .userInitiated) { handle.isFocusedInApp() }.value
        guard focused else { return nil }
        permissions.refreshMicrophone()
        guard isCurrent(r), !r.cloudInvalidated, observesContextSwitches(), permissions.microphone == .granted,
              Self.frontmost().pid == r.frontmostPID, !isPaused() else { return nil }
        return OpenAITranscription.eligibleContext(
            sample.context, identity: sample.identity, fieldPID: handle.pid,
            policy: SnapshotPolicy.current(db), paused: (try? store.isPaused(now: .now)) != false,
            secureInput: IsSecureEventInputEnabled())
    }

    /// The privacy route for the cleanup: password managers and vault pages refuse; excluded,
    /// private, unknown or unverifiable contexts clean on-device only (`CleanupRoute.forDictation`).
    private func cleanupRoute(field: FocusedField?, _ r: Run) async -> CleanupRoute {
        let sample = await windows.readContext()
        return CleanupRoute.forDictation(
            context: sample?.context, contextPID: sample?.identity.pid, fieldPID: field?.handle.pid ?? r.frontmostPID,
            fieldBundleID: field?.bundleID, policy: policy(), paused: isPaused())
    }

    /// The user's exclusions; unreadable rules fail closed (nothing is capturable).
    private func policy() -> CapturePolicy {
        do { return CapturePolicy(userRules: try ExclusionStore(db).all().compactMap(ExclusionRule.init(pattern:))) } catch {
            Self.log.error("exclusions unreadable; dictation cleanup stays on-device")
            return .denyAll
        }
    }

    func cancelSession() {
        guard let r = run else { return }
        run = nil
        r.work?.cancel()
        r.events?.cancel()
        r.cloudRequest?.cancel()
        if let session = r.session { Task { await session.cancel() } }
        if r.raw == nil { rewrite.restoreDraftAfterRecording() }
        sessionLocale = nil
        phase = .idle
    }

    private func end(_ r: Run, notice: DictationNotice?) {
        guard isCurrent(r) else { return }
        cancelSession()
        if let notice { rewrite.showDictationNotice(notice) }
    }

    private func isCurrent(_ r: Run) -> Bool { run === r }

    func perform(_ action: NoticeAction) {
        switch action {
        case .openMicrophoneSettings: permissions.openMicrophoneSettings()
        case .openDictationSettings: openDictationSettings()
        }
    }

    /// The popover's language badge: re-transcribes in the other language when it is installed, and
    /// moves the quick-switch pin with it when one is set.
    func switchSessionLocale() {
        guard let r = run, r.started, !r.finishing, let session = r.session, let current = sessionLocale else { return }
        let next = current.other
        guard speechAssets.state(next) == .installed else {
            NSSound.beep()
            return
        }
        if settings.pinnedLocale != nil { setPinned(next) }
        Task {
            do { try await session.switchLocale(next) } catch {
                Self.log.error("dictation locale switch failed: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    // MARK: - Helpers

    private var soundsEnabled: Bool { rewrite.shortcuts.soundsEnabled }

    private func chooseLocale(_ appKey: String?) -> DictationLocale {
        LocaleChooser.choose(pinned: settings.pinnedLocale, appKey: appKey, memory: localeMemory,
                             defaultLocale: settings.defaultLocale)
    }

    private func remember(_ l: DictationLocale, for appKey: String?) {
        guard appKey != nil else { return }
        localeMemory.record(l, for: appKey, at: .now)
        do { try store.setValue(localeMemory, forKey: LocaleMemory.settingsKey) } catch {
            Self.log.error("dictation language memory not saved")
        }
    }

    private static func frontmost() -> (appKey: String?, pid: pid_t?, bundleID: String?) {
        let app = NSWorkspace.shared.frontmostApplication
        return (AppKey.make(bundleID: app?.bundleIdentifier, appName: app?.localizedName), app?.processIdentifier,
                app?.bundleIdentifier)
    }

    /// The notice's case only (never text).
    private static func kind(_ n: DictationNotice) -> String {
        switch n {
        case .microphoneDenied: "microphoneDenied"
        case .microphoneRequested: "microphoneRequested"
        case .unsupported: "unsupported"
        case .assetDownloading(let l, _): "assetDownloading-\(l.rawValue)"
        case .assetMissing(let l): "assetMissing-\(l.rawValue)"
        case .localeUnsupported(let l): "localeUnsupported-\(l.rawValue)"
        case .microphoneNotReady: "microphoneNotReady"
        case .nothingHeard: "nothingHeard"
        case .cleanupSkipped: "cleanupSkipped"
        case .openAITranscriptionUnavailable: "openAITranscriptionUnavailable"
        case .secureField: "secureField"
        case .copiedInstead: "copiedInstead"
        case .limitReached: "limitReached"
        case .microphoneLost: "microphoneLost"
        case .failed: "failed"
        }
    }
}
