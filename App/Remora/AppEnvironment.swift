import AppKit
import Assistant
import Capture
import ChatBar
import Dictation
import Embeddings
import Foundation
import Indicator
import Input
import Lifecycle
import LLM
import MCPServer
import Memory
import Observation
import os
import Retrieval
import Rewrite
import Storage
import SwiftUI

extension PauseDuration {
    var title: String {
        switch self {
        case .minutes15: "15 minutes"
        case .hour1: "1 hour"
        case .untilTomorrow: "Until tomorrow"
        case .indefinitely: "Indefinitely"
        }
    }
}

enum SettingsTab: Hashable { case general, account, usage, memory, identity, shortcuts, dictation, privacy, appearance, mcp, meetingSources, notifications, logs }

/// Lets the indicator's closures reach the environment before `init` has finished.
@MainActor
private final class WeakEnvironment {
    weak var value: AppEnvironment?
}

@MainActor @Observable
final class AppEnvironment {
    let db: AppDatabase
    let engine: CaptureEngine
    let permissions = PermissionsMonitor()
    let loginItem = LoginItem()
    let indicator: IndicatorController
    let account: AccountModel
    let llm: LLMService
    /// The price table (built-in prices overlaid by `model-prices.json`); Settings › Usage reads it.
    let prices: PriceTableFile
    let rewriteEngine: RewriteEngine
    let rewrite: RewriteController
    let speechAssets: SpeechAssetModel
    let dictation: DictationController
    let memory: MemoryController
    @ObservationIgnored private(set) lazy var meetingRecording = MeetingRecordingController(env: self)
    var meetingSessionAvailable: Bool { scheduler.sessionAvailable }
    let meetingSources: MeetingSourcesModel
    /// Created by `RemoraApp` before the database opens, so updates also work when it can't.
    let updater: UpdaterController
    /// The chat bar: its model and panel. Actions it takes reach the app through `ChatEffects`.
    let reminders: ReminderEngine
    let chat: ChatModel
    let bar: ChatBarController
    /// Briefs, nudges, reminders and macOS notifications.
    let proactive: ProactiveController
    @ObservationIgnored private let badge: WindowBadgeController
    /// Optional per-window badge. Read once at launch; setting it persists and applies at once.
    var windowBadgeEnabled = false {
        didSet {
            guard windowBadgeEnabled != oldValue else { return }
            do { try settings.setWindowBadgeEnabled(windowBadgeEnabled) } catch {
                fail("badge setting not saved", error, message: "Could not save the badge setting.")
            }
            badge.setEnabled(windowBadgeEnabled)
        }
    }
    /// The Settings tab shown next time the window opens (bound to `SettingsView`).
    var settingsTab: SettingsTab = .general
    /// Set by the always-alive menu-bar label, which has access to `\.openSettings`.
    @ObservationIgnored var settingsOpener: (@MainActor () -> Void)?

    /// Pause deadline; `nil` when not paused (or when the stored value is unreadable).
    private(set) var pausedUntil: Date?
    /// The stored pause value is corrupt: status shows it and Resume clears it.
    private(set) var pauseUnreadable = false
    /// Last failure of a user-triggered storage action, for display.
    var lastError: String?
    private(set) var isDeletingAll = false

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let scheduler: CaptureScheduler
    @ObservationIgnored private var expiryTimer: Timer?
    @ObservationIgnored private lazy var onboarding = OnboardingController(env: self)
    @ObservationIgnored private let logger = Logger(subsystem: "dev.remora", category: "app")

    var isCapturing: Bool {
        permissions.accessibilityGranted && pausedUntil == nil && !pauseUnreadable
    }

    init(db: AppDatabase, updater: UpdaterController) {
        self.db = db
        self.updater = updater
        meetingSources = MeetingSourcesModel(db: db)
        let reader = FrontmostWindowReader()
        // 3 s: measured Mail 0.85 s and Electron 0.6 s; 500 ms never captures them.
        engine = CaptureEngine(reader: reader, db: db, readTimeout: .seconds(3))
        scheduler = CaptureScheduler(engine: engine, reader: reader)
        let settings = SettingsStore(db)
        self.settings = settings
        // LLM stack: nothing here makes a network call until the user signs in.
        let http = URLSessionTransport()
        let validator = IDTokenValidator(jwks: URLJWKSProvider(fetch: { try await http.data(for: $0) }))
        let tokens = TokenManager(store: KeychainCredentialStore(), http: http, validator: validator)
        let models = ModelCatalog(http: http, tokens: tokens, settings: settings)
        // The catalog is filled from the cache when the account model starts.
        let box = LLMSnapshotBox(routing: AccountModel.loadRouting(settings), catalog: [])
        let onDeviceModel = SystemOnDeviceModel()
        let prices = PriceTableFile()
        self.prices = prices
        let calls = LLMCallStore(db)
        let service = LLMService(
            siwc: SIWCClient(tokens: tokens, responses: ResponsesClient(http: http)),
            onDevice: FoundationModelsClient(model: onDeviceModel),
            onDeviceAvailability: { onDeviceModel.availability },
            calls: calls, routing: { box.routing }, catalog: { box.catalog },
            prices: { prices.table() }, settings: settings)
        llm = service
        // Memory: one embedder that never requests assets on the rewrite path (SharedEmbedder).
        let calendar = PeriodKey.localCalendar  // pinned: ISO 8601, local zone; never Calendar.current
        let embedder = SharedEmbedder()
        let index = VectorIndex(db: db)
        let search = HybridSearch(db: db, embedder: embedder, index: index, policy: { SnapshotPolicy.current(db) })
        rewriteEngine = RewriteEngine(llm: service,
                                      context: ContextAssembler(db: db, search: search, expander: LLMQueryExpander(llm: service)),
                                      outputs: InlineOutputStore(db), calls: calls)
        account = AccountModel(
            tokens: tokens,
            flow: SignInFlow(tokens: tokens, http: http, validator: validator, browser: SystemBrowser()),
            models: models, settings: settings, onDeviceModel: onDeviceModel, box: box)
        let weakSelf = WeakEnvironment()
        // Proactive messages land here once delivered (chat reload, macOS notification).
        let inbox = ProactiveInbox(db: db, onDelivered: { m in await weakSelf.value?.proactive.delivered(m) })
        // Briefs and nudges are scheduler jobs; only `JobPlanner` owns the planner watermark.
        // Every job kind has a runner (`RunnerCoverageTests`). The embeddings job is the one
        // background path allowed to download the model (idle and on power); compaction and the
        // forget-triggered digest rebuild never request assets.
        let runners = MemoryRunners.make(db: db, llm: service, embedder: embedder,
                                         backgroundEmbedder: OnPowerEmbedder(shared: embedder),
                                         dbURL: AppDatabase.defaultURL, calendar: calendar)
            .merging(ProactiveController.runners(db: db, llm: service, inbox: inbox)) { memory, _ in memory }
        memory = MemoryController(
            db: db,
            scheduler: MemoryScheduler(db: db, runners: runners,
                                       planner: CompositePlanner([
                                           JobPlanner(db: db, data: DatabasePlannerData(db: db), calendar: calendar),
                                           ProactiveController.planner(db: db, calendar: calendar),
                                       ]),
                                       calendar: calendar),
            account: account, embedder: embedder, index: index, calendar: calendar)
        // Chat: the MCP memory tools (same filtering), time report, routines, guide and actions.
        let reminders = ReminderEngine(store: ReminderStore(db), db: db, calendar: { PeriodKey.localCalendar })
        self.reminders = reminders
        let effects = ChatEffects(target: weakSelf)
        let toolbox = ChatToolbox(
            MemoryToolAdapter.all(MemoryTools(databaseURL: AppDatabase.defaultURL, embedder: { embedder }))
                + [TimeReportTool(db: db), RoutineSuggestionsTool(db: db), GuideTool(),
                   SearchMeetingsTool(importer: meetingSources.importer, db: db), SearchRecordedMeetingsTool(db: db),
                   SearchSavedNotesTool(db: db)]
                + ActionTools.all(reminders: reminders, db: db, effects: effects))
        let agent = ChatAgent(db: db, llm: service, toolbox: toolbox, store: ChatStore(db), calls: calls,
                              calendar: { PeriodKey.localCalendar })
        let chat = ChatModel(agent: agent, db: db, toolKinds: { toolbox.kind(of: $0) }, reminders: reminders,
                             effects: effects)
        self.chat = chat
        let bar = ChatBarController(model: chat, settings: settings)
        self.bar = bar
        // A notification click opens the chat on its message.
        let poster = SystemNotificationPoster(onOpen: { [weak bar] id in bar?.openMessage(inboxID: id) })
        proactive = ProactiveController(db: db, inbox: inbox, poster: poster, reminders: reminders, agent: agent,
                                        chat: chat)
        rewrite = RewriteController(
            engine: rewriteEngine, account: account, db: db, windows: reader,
            isPaused: { weakSelf.value?.isPaused ?? true },
            openAccountSettings: { weakSelf.value?.openSettings(tab: .account) })
        // Nothing here touches the microphone or downloads a speech model.
        let speechAssets = SpeechAssetModel(assets: SystemSpeechAssets())
        self.speechAssets = speechAssets
        dictation = DictationController(
            rewrite: rewrite, permissions: permissions, speechAssets: speechAssets, llm: service, db: db,
            windows: reader, isPaused: { weakSelf.value?.isPaused ?? true },
            observesContextSwitches: { weakSelf.value?.scheduler.observesContextSwitches ?? false },
            openDictationSettings: { weakSelf.value?.openSettings(tab: .dictation) })
        rewrite.dictation = dictation
        // The rewrite key with nothing focused opens the chat (a secure field still beeps).
        rewrite.openChat = { weakSelf.value?.bar.open(focusInput: true) }
        bar.actions = ChatBarController.Actions(
            openSettings: { weakSelf.value?.openSettings(tab: .appearance) },
            openAccountSettings: { weakSelf.value?.openSettings(tab: .account) })
        let permissions = permissions
        indicator = IndicatorController(
            engine: engine,
            isPaused: { weakSelf.value?.isPaused ?? true },
            accessibilityGranted: { permissions.accessibilityGranted })
        badge = WindowBadgeController(reader: reader, indicator: indicator,
                                      perform: { weakSelf.value?.perform($0) })
        weakSelf.value = self
        // Read once; a throw counts as off and is logged once. No didSet during init.
        do { windowBadgeEnabled = try settings.windowBadgeEnabled() } catch {
            logger.error("badge setting unreadable: \(String(describing: type(of: error)), privacy: .public)")
        }
        dictation.onTranscriptionKeyChanged = { [weak self] in self?.meetingRecording.transcriptionKeyChanged() }
        scheduler.onSessionInactive = { [weak self] in self?.meetingRecording.discard() }
        scheduler.onWindowEvent = { [weak self] in self?.badge.windowEvent($0) }
        indicator.onStateChange = { [weak self] _ in self?.badge.stateChanged() }
        scheduler.isPaused = { [weak self] in self?.isPaused ?? true }
        scheduler.onContextSample = { [weak self] in self?.indicator.contextSampled($0) }
        scheduler.onContextSwitch = { [weak self] in self?.dictation.invalidateCloudTranscription() }
        permissions.onChange = { [weak self] granted in self?.permissionChanged(granted) }
        permissions.onTick = { [weak self] in
            self?.refreshPause()
            self?.rewrite.refreshSecureInput()
            self?.onboarding.refresh()
        }
        loginItem.registerOnFirstLaunch()
        Task.detached(priority: .utility) { SafariPrivateTitle.prewarm() }
        // After launch completes, so the onboarding window can be shown.
        Task { @MainActor [weak self] in self?.launch() }
    }

    // MARK: - Status

    var statusText: String {
        if !permissions.accessibilityGranted { return "Needs Accessibility" }
        if pauseUnreadable { return "Paused (settings unreadable)" }
        if let until = pausedUntil {
            return until == .distantFuture ? "Paused indefinitely" : "Paused until \(Self.format(until))"
        }
        return "Capturing"
    }

    /// The Remora mark for active capture, with dedicated symbols for pause and permissions.
    var menuBarSymbol: String {
        if !permissions.accessibilityGranted { return "exclamationmark.triangle" }
        return isCapturing ? RemoraBrand.glyphName : "pause.circle"
    }

    var isPaused: Bool { pausedUntil != nil || pauseUnreadable }

    /// An update never installs (and restarts Remora) while this is true. `chat.isStreaming` is
    /// the chat turn in flight (from send until its reply is stored).
    var isBusyForUpdate: Bool {
        rewrite.isWorking || rewrite.isEditing || dictation.isActive || isDeletingAll || memory.isRunningJob
            || onboarding.isShowing || chat.isStreaming || meetingRecording.busy
    }

    private static func format(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = Calendar.current.isDateInToday(date) ? .none : .medium
        return f.string(from: date)
    }

    // MARK: - Pause

    func pause(for duration: PauseDuration) {
        do {
            try settings.pause(until: duration.end(from: .now))
            lastError = nil
        } catch {
            fail("pause failed", error, message: "Could not pause capture.")
        }
        refreshPause()
    }

    func resume() {
        do {
            try settings.pause(until: nil)  // also clears a corrupt stored value
            lastError = nil
        } catch {
            fail("resume failed", error, message: "Could not resume capture.")
        }
        refreshPause()
    }

    /// Re-reads the pause setting; call when the menu opens.
    func refresh() {
        refreshPause()
        rewrite.refreshSecureInput()
    }

    private func refreshPause() {
        do {
            let until = try settings.pausedUntil()
            pausedUntil = until.flatMap { $0 > .now ? $0 : nil }
            pauseUnreadable = false
        } catch {
            if !pauseUnreadable {  // log once per transition, not every 2 s tick
                logger.error("pause setting unreadable: \(String(describing: type(of: error)), privacy: .public)")
            }
            pausedUntil = nil
            pauseUnreadable = true
        }
        if isPaused {
            dictation.invalidateCloudTranscription()
            meetingRecording.discard()
        }
        expiryTimer?.invalidate()
        expiryTimer = nil
        if let until = pausedUntil, until != .distantFuture {
            let timer = Timer(fire: until.addingTimeInterval(0.5), interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshPause() }
            }
            RunLoop.main.add(timer, forMode: .common)
            expiryTimer = timer
        }
        indicator.refresh()
    }

    // MARK: - Data

    /// Deletes snapshots (+FTS) and activity in one transaction, off the main actor.
    /// Capture is held off meanwhile: the scheduler is stopped and a temporary indefinite
    /// pause stops any in-flight tick from storing; the previous pause is restored after.
    func deleteAllData() async throws {
        guard !isDeletingAll else { return }
        isDeletingAll = true
        defer { isDeletingAll = false }
        let previous = try? settings.pausedUntil()
        let previousReadable = !pauseUnreadable
        // Without the barrier pause an in-flight capture could land after the delete: abort.
        do { try settings.pause(until: .distantFuture) } catch {
            fail("delete barrier pause failed", error, message: "Could not start deletion.")
            throw error
        }
        scheduler.stop()
        refreshPause()
        rewrite.closeEditBar()
        let db = db
        // Background memory is held off too: no job may land after the delete (Task 1 wipes memory).
        await memory.suspendForReset()
        meetingSources.prepareForReset()
        defer {
            memory.resume()
            meetingSources.start()
            if previousReadable { try? settings.pause(until: previous) }
            refreshPause()
            if permissions.accessibilityGranted { scheduler.start() }
        }
        do {
            try await Task.detached { try DataReset.deleteAllCapturedData(in: db) }.value
        } catch let error as DataReset.CleanupPending {
            await meetingSources.didReset()
            await proactive.dataDeleted()
            throw error
        }
        await meetingSources.didReset()
        // Nothing wiped may stay on screen: notifications, the running turn, the chat panel.
        await proactive.dataDeleted()
    }

    // MARK: - Wiring

    private func launch() {
        // Before capture starts, so the first tick already honours them. Failure is logged
        // only: the user can still add the rules by hand.
        do { try ExclusionStore(db).seedDefaults() } catch {
            logger.error("default exclusions seed failed: \(String(describing: type(of: error)), privacy: .public)")
        }
        // A delete-all whose on-disk scrub failed left a flag: retry the scrub now, off main.
        let db = db, logger = logger
        Task.detached(priority: .utility) {
            do { try DataReset.scrubIfPending(in: db) } catch {
                logger.error("pending scrub failed: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
        // Calls recorded before their model had a price get one now, so every surface reading the
        // stored cost agrees. Never rewrites a stored cost.
        let prices = prices
        Task.detached(priority: .utility) {
            do { _ = try UsageRepricer.backfill(store: LLMCallStore(db), prices: prices.table()) } catch {
                logger.error("usage backfill failed: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
        refreshPause()
        indicator.start()
        badge.setEnabled(windowBadgeEnabled)
        account.onWelcome = { [weak self] in self?.openSettings(tab: .account) }
        account.start()
        memory.start()
        meetingSources.start()
        bar.start()
        proactive.start()
        if permissions.accessibilityGranted {
            scheduler.start()
            rewrite.start()
            dictation.start()
        }
        meetingRecording.watch()
        showOnboardingIfNeeded()
    }

    // MARK: - Onboarding

    /// What the onboarding flow is driven by, read fresh each time.
    var onboardingFacts: OnboardingFacts {
        OnboardingFacts(
            accessibilityGranted: permissions.accessibilityGranted,
            signedIn: account.presentation.isSignedInWithPlanUsage,
            notificationsAsked: (try? settings.value(Bool.self, forKey: ProactiveNotifications.askedKey)) ?? false)
    }

    /// At launch: always while Accessibility is missing; otherwise once the sign-in state is known,
    /// to a signed-out user who never clicked Done. (`LaunchGate` already ran: a copy that quits or
    /// moves itself never gets here.)
    private func showOnboardingIfNeeded() {
        let stored = (try? settings.value(Bool.self, forKey: OnboardingController.completedKey)) ?? false
        let legacy = (try? settings.value(Bool.self, forKey: OnboardingController.legacySignInOfferedKey)) ?? false
        let completed = OnboardingFlow.effectiveCompleted(completed: stored, legacySignInOffered: legacy)
        if completed, !stored { markOnboardingCompleted() }  // an upgrade from the sign-in offer
        guard permissions.accessibilityGranted else {
            onboarding.show()
            return
        }
        guard !completed else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await account.refreshState()
            if OnboardingFlow.shouldShowAtLaunch(completed: completed, facts: onboardingFacts) { onboarding.show() }
        }
    }

    /// "Done" on the last onboarding step.
    func markOnboardingCompleted() {
        do { try settings.setValue(true, forKey: OnboardingController.completedKey) } catch {
            logger.error("onboarding.completed not saved: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    /// Grant/revoke transition. A grant moves an open onboarding past its Accessibility step; a revoke
    /// shows onboarding again.
    private func permissionChanged(_ granted: Bool) {
        defer { indicator.refresh() }
        if granted {
            scheduler.start()  // idempotent; the engine itself honors pause
            rewrite.start()
            dictation.start()
            onboarding.refresh()
        } else {
            meetingRecording.interrupt(reason: "Meeting recording lost Accessibility permission.")
            scheduler.stop()
            rewrite.stop()
            dictation.stop()
            onboarding.show()
        }
    }

    // MARK: - Chat actions

    /// Applies what a chat action (or its undo) changed in storage to the running app.
    func applyActionChange(_ change: ActionChange) {
        switch change {
        case .pause: refresh()
        case .exclusions:
            meetingSources.exclusionsChanged()
            meetingRecording.policyChanged()
            indicator.refresh(reloadRules: true)
            chat.reload()
        // Forgotten captures can still be named by the digest: rebuild the digest alone.
        case .snapshots:
            memory.rebuildDigestAfterForget()
            chat.reload()
        case .reminders: proactive.remindersChanged()
        case .identity, .wiki, .routines: break  // read fresh where used
        case .setting(let name): applySetting(name)
        }
    }

    private func applySetting(_ name: String) {
        switch name {
        case "bar_position", "open_on_hover", "auto_hide_bar", "dim_bar_when_unfocused", "text_size":
            bar.reloadSettings()
        case "window_badge":
            do { windowBadgeEnabled = try settings.windowBadgeEnabled() } catch {
                logger.error("badge setting unreadable: \(String(describing: type(of: error)), privacy: .public)")
            }
        case "dictation":
            if let s = try? settings.value(DictationSettings.self, forKey: DictationSettings.settingsKey) { dictation.update(s) }
        case "sounds":
            if let s = try? settings.value(ShortcutSettings.self, forKey: ShortcutSettings.settingsKey) { rewrite.updateShortcuts(s) }
        case "memory_language", "background_memory", "raw_capture_retention":
            memory.settingsChangedElsewhere()
        case "proactive_messages":
            proactive.reloadEnabled()  // the runners and planner read it fresh
        default: break
        }
    }

    // MARK: - Quick menu

    func perform(_ item: QuickMenuItem) {
        switch item {
        case .neverCaptureApp, .neverCaptureSite:
            // Same validation as the Privacy tab: only a pattern the capture rules can match is stored.
            guard let pattern = item.exclusionPattern, let rule = ExclusionRule(pattern: pattern) else {
                lastError = "Could not update the ignore list."
                break
            }
            do {
                try ExclusionStore(db).add(rule.pattern)
                meetingRecording.policyChanged()
                meetingSources.exclusionsChanged()
                chat.reload()
                lastError = nil
            } catch {
                fail("quick-menu exclusion failed", error, message: "Could not update the ignore list.")
            }
        case .pause15, .resume:
            // The badge menu bypasses the SwiftUI `.disabled`: nothing may change mid delete-all.
            guard !isDeletingAll else { return }
            if item == .pause15 { pause(for: .minutes15) } else { resume() }
        case .openPrivacySettings: openSettings(tab: .privacy)
        }
        indicator.refresh(reloadRules: true)
    }

    func openSettings(tab: SettingsTab) {
        settingsTab = tab
        NSApp.activate()
        if let settingsOpener {
            settingsOpener()
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }

    /// "Show onboarding again" and the menu's "Grant Accessibility…": a fresh flow (or the open window).
    func showOnboarding() { onboarding.show() }

    /// The menu's "Continue with ChatGPT…": shows Settings › Account (for the waiting state) and starts.
    func continueWithChatGPT() {
        openSettings(tab: .account)
        Task { await account.signIn() }
    }

    private func fail(_ log: StaticString, _ error: any Error, message: String) {
        logger.error("\(log, privacy: .public): \(String(describing: type(of: error)), privacy: .public)")
        lastError = message
    }
}

/// `ActionEffects` for the chat's action tools: hops to the main actor and applies the change.
private final class ChatEffects: ActionEffects {
    private let target: WeakEnvironment

    init(target: WeakEnvironment) { self.target = target }

    func didChange(_ c: ActionChange) async {
        await MainActor.run { target.value?.applyActionChange(c) }
    }
}
