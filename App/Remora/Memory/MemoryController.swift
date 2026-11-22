import AppKit
import Capture
import Embeddings
import Foundation
import LLM
import Memory
import Observation
import os
import Storage

/// Runs background memory: ticks `MemoryScheduler` every 60 s, after wake (system and screens)
/// and on sign-in, with signals from `SchedulerSignals.make` (F-46). Ticks never overlap. Also
/// serves Settings › Memory, Identity and the Usage budget section.
///
/// - Memory turned off, sign-out (account ready → not ready) and system sleep: the running job is
///   cancelled through `MemoryScheduler.cancelCurrent`, so it goes back to pending without an
///   attempt (a job left running across sleep would otherwise time out on wake and count one).
/// - Quit: `stop` (wired to `NSApplication.willTerminateNotification`) cancels the running job and
///   the idle watcher.
/// - The user returns while a tick planned on idle signals runs idle-gated work: cancelled
///   (`IdleReturn.shouldCancel`, T2-M5).
/// - "Run now" buttons use `MemoryScheduler.runNow` (F-9): run condition waived, budget, backoff
///   and memory-off never.
/// - The vector cache is warmed off the rewrite path: 30 s after launch and after embeddings or
///   compaction, only with memory on and the model downloaded (`MemoryLifecycle`).
/// - Status: a light refresh (no `awaitingSummary`) after each tick; a full one when Settings ›
///   Memory or Usage appears and after compaction. One at a time (`StatusRefreshGate`).
///
/// Logs kinds, counts and codes only.
@MainActor @Observable
final class MemoryController {
    static let tickInterval: TimeInterval = 60
    static let idleWatchInterval: Duration = .seconds(5)

    private(set) var counts: [JobStatus: Int] = [:]
    private(set) var lastCompaction: CompactionReport?
    private(set) var budgetUsed = 0
    private(set) var budget = MemorySettings.defaultDailyTokenBudget
    private(set) var backoffUntil: Date?
    private(set) var dbSize: (main: Int64, wal: Int64) = (0, 0)
    /// Old raw captures held back until memory summarises them (F-36).
    private(set) var awaitingSummary = 0
    private(set) var statusUnreadable = false
    private(set) var enabled = true
    private(set) var language: MemoryLanguage = .en
    private(set) var retention: RetentionSetting = MemorySettings.defaultRetention
    /// nil while unknown.
    private(set) var embeddingModelReady: Bool?
    private(set) var isDownloadingModel = false
    private(set) var runningNow: Set<JobKind> = []
    /// A user-facing line about the last settings write or "Run now".
    var message: String?

    let calendar: Calendar
    @ObservationIgnored private let db: AppDatabase
    @ObservationIgnored private let scheduler: MemoryScheduler
    @ObservationIgnored private let account: AccountModel
    @ObservationIgnored private let embedder: SharedEmbedder
    @ObservationIgnored private let index: VectorIndex
    @ObservationIgnored private let settings: MemorySettings
    @ObservationIgnored private var started = false
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private var ticking = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var terminateObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var accountWasReady = false
    @ObservationIgnored private var idleWatcher: Task<Void, Never>?
    @ObservationIgnored private var warmTask: Task<Void, Never>?
    @ObservationIgnored private var refreshGate = StatusRefreshGate()
    @ObservationIgnored private static let log = Logger(subsystem: "dev.remora", category: "memory")

    init(db: AppDatabase, scheduler: MemoryScheduler, account: AccountModel, embedder: SharedEmbedder,
         index: VectorIndex, calendar: Calendar) {
        self.db = db; self.scheduler = scheduler; self.account = account; self.embedder = embedder
        self.index = index; self.calendar = calendar
        settings = MemorySettings(SettingsStore(db))
    }

    // MARK: - Lifecycle

    /// Idempotent. Resets jobs left running, then ticks.
    func start() {
        guard !started else { return }
        started = true
        reloadSettings()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            })
        }
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.cancelRunningJob(reason: "sleep") }
        })
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        accountWasReady = Self.ready(account.state)
        observeAccount()
        ticking = true  // no tick before launch has reset the running rows
        let scheduler = scheduler
        Task { [weak self] in
            do { try await scheduler.launch(now: .now) } catch {
                Self.log.error("memory launch failed: \(String(describing: type(of: error)), privacy: .public)")
            }
            guard let self else { return }
            ticking = false
            startTimer()
            tick()
        }
        warmIndex(after: MemoryLifecycle.warmIndexDelay)
        refreshStatus(full: true)
    }

    /// At quit (and idempotent): no more ticks; the running job and the idle watcher are cancelled.
    func stop() {
        timer?.invalidate()
        timer = nil
        for o in observers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        observers = []
        if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }
        terminateObserver = nil
        idleWatcher?.cancel()
        idleWatcher = nil
        warmTask?.cancel()
        warmTask = nil
        if started { cancelRunningJob(reason: "stop") }
        started = false
    }

    /// The running job goes back to pending without an attempt (`MemoryScheduler.cancelCurrent`).
    private func cancelRunningJob(reason: String) {
        Self.log.info("memory job cancelled: \(reason, privacy: .public)")
        let scheduler = scheduler
        Task { await scheduler.cancelCurrent() }
    }

    /// Before "Delete all data": no tick or "Run now" until `resume`; the running job is cancelled
    /// and awaited.
    func suspendForReset() async {
        suspended = true
        timer?.invalidate()
        timer = nil
        await scheduler.suspend()
    }

    func resume() {
        let scheduler = scheduler
        Task { [weak self] in
            await scheduler.resume()
            guard let self else { return }
            suspended = false
            reloadSettings()
            if started { startTimer(); tick() }
            refreshStatus(full: true)
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func observeAccount() {
        withObservationTracking { _ = account.state } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let ready = Self.ready(account.state)
                if ready, !accountWasReady { tick() }
                if MemoryLifecycle.cancelsOnAccountChange(wasReady: accountWasReady, isReady: ready) {
                    cancelRunningJob(reason: "sign_out")
                }
                accountWasReady = ready
                observeAccount()
            }
        }
    }

    private static func ready(_ state: SignInState) -> Bool {
        if case .signedIn(_, true) = state { return true }
        return false
    }

    /// A tick or a "Run now" is in progress (an update never restarts Remora mid-job, e.g. mid-compaction).
    var isRunningJob: Bool { ticking || !runningNow.isEmpty }

    // MARK: - Ticks

    private func signals() -> SchedulerSignals {
        SchedulerSignals.make(account: account.state, onDevice: account.onDevice, idle: SystemSignals.idleSeconds(),
                              power: SystemSignals.onACPower(), lowPower: SystemSignals.lowPower,
                              memoryEnabled: settings.enabled(), now: .now)
    }

    /// A no-op while a tick runs, while suspended or before `start`.
    private func tick() {
        guard started, !suspended, !ticking else { return }
        ticking = true
        let s = signals()
        let scheduler = scheduler
        idleWatcher?.cancel()
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.idleWatchInterval)
                guard !Task.isCancelled else { return }
                let kind = await scheduler.runningKind()
                if IdleReturn.shouldCancel(tickIdleSeconds: s.idleSeconds, nowIdleSeconds: SystemSignals.idleSeconds(),
                                           runningKind: kind), !Task.isCancelled {
                    Self.log.info("user returned: idle-gated memory work cancelled")
                    await scheduler.cancelCurrent()
                    return
                }
            }
        }
        idleWatcher = watcher
        Task { [weak self] in
            let report = await scheduler.tick(s)
            watcher.cancel()
            self?.tickFinished(report)
        }
    }

    private func tickFinished(_ report: TickReport) {
        ticking = false
        idleWatcher = nil
        if !report.ran.isEmpty { Self.log.info("memory tick ran \(report.ran.count, privacy: .public) jobs") }
        if report.ran.contains(.embeddings) || report.ran.contains(.compaction) { warmIndex() }
        refreshStatus(full: report.ran.contains(.compaction))
    }

    // MARK: - Run now (F-9)

    func runCompactionNow() {
        runNow(.compaction, key: PeriodKey.key(.day, for: .now, calendar: calendar))
    }

    func regenerateIdentity() {
        runNow(.identity, key: PeriodKey.key(.week, for: .now, calendar: calendar))
    }

    /// After a forget (chat `forget_snapshots`): marks the digest dirty and rebuilds only the
    /// digest (`ForgetFollowUp`), never a full compaction. When the gate denies it, the pending job
    /// and the dirty mark make a later tick or tonight's compaction rebuild it. No Settings message.
    func rebuildDigestAfterForget() {
        guard !suspended else { return }
        let s = signals()
        let db = db, scheduler = scheduler, calendar = calendar
        Task {
            let report = await ForgetFollowUp.rebuildDigest(db: db, scheduler: scheduler, signals: s, calendar: calendar)
            Self.log.info("digest after forget: \(report.ran.contains(.digestRebuild) ? "rebuilt" : "deferred", privacy: .public)")
        }
    }

    private func runNow(_ kind: JobKind, key: String) {
        guard !suspended, !runningNow.contains(kind) else { return }
        runningNow.insert(kind)
        message = nil
        let s = signals()
        let scheduler = scheduler
        Task { [weak self] in
            let report = await scheduler.runNow(kind: kind, periodKey: key, signals: s)
            guard let self else { return }
            runningNow.remove(kind)
            if !report.ran.contains(kind) {
                message = Self.notRunMessage(report, kind: kind, s)
            }
            if kind == .compaction { warmIndex() }
            refreshStatus(full: kind == .compaction)
        }
    }

    private static func notRunMessage(_ r: TickReport, kind: JobKind, _ s: SchedulerSignals) -> String {
        if !s.memoryEnabled, kind != .compaction { return "Turn on background memory first." }
        if r.postponedForLimit { return "Paused by the ChatGPT usage limit. Try again later." }
        if r.stoppedForBudget { return "Today's background budget is used up." }
        if !s.accountReady, kind != .compaction { return "Continue with ChatGPT first." }
        return "Nothing to run right now."
    }

    // MARK: - Settings

    func setEnabled(_ on: Bool) {
        write { try settings.setEnabled(on) }
        enabled = settings.enabled()
        if on {
            tick()
            warmIndex()
        } else {
            cancelRunningJob(reason: "memory_off")
        }
        refreshStatus(full: true)
    }

    func setLanguage(_ l: MemoryLanguage) {
        write { try settings.setLanguage(l) }
        language = settings.language()
    }

    func setRetention(_ r: RetentionSetting) {
        write { try settings.setRetention(r) }
        retention = settings.retention()
        refreshStatus(full: true)
    }

    func setDailyBudget(_ n: Int) {
        write { try settings.setDailyTokenBudget(n) }
        budget = settings.dailyTokenBudget()
    }

    /// A chat action changed a memory setting in storage: show it, and stop a running job when
    /// memory was turned off.
    func settingsChangedElsewhere() {
        let wasEnabled = enabled
        reloadSettings()
        if wasEnabled, !enabled { cancelRunningJob(reason: "memory_off") }
        refreshStatus(full: true)
    }

    private func write(_ body: () throws -> Void) {
        do { try body(); message = nil } catch {
            Self.log.error("memory setting not saved: \(String(describing: type(of: error)), privacy: .public)")
            message = "Could not save the setting."
        }
    }

    private func reloadSettings() {
        enabled = settings.enabled()
        language = settings.language()
        retention = settings.retention()
        budget = settings.dailyTokenBudget()
    }

    // MARK: - Embedding model

    /// Explicit user action: downloads the language model assets if missing.
    func downloadEmbeddingModel() {
        guard !isDownloadingModel else { return }
        isDownloadingModel = true
        let embedder = embedder
        Task { [weak self] in
            let id = await embedder.requestAssets()
            guard let self else { return }
            isDownloadingModel = false
            embeddingModelReady = id != nil
            if id == nil { message = "The language model could not be downloaded." }
            warmIndex()
        }
    }

    /// Loads the model and the vector cache in the background (after `delay`), so the rewrite's
    /// memory bound is not spent on a cache reload. Never requests assets; skipped with memory off
    /// or the model not downloaded (`MemoryLifecycle.shouldWarmIndex`).
    private func warmIndex(after delay: Duration = .zero) {
        let embedder = embedder, index = index, settings = settings
        warmTask?.cancel()
        warmTask = Task.detached(priority: .utility) { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let downloaded = embedder.modelDownloaded()
            guard MemoryLifecycle.shouldWarmIndex(memoryEnabled: settings.enabled(), modelDownloaded: downloaded) else {
                if !downloaded { await self?.setModelReady(false) }
                return
            }
            let id = await embedder.identity()
            await self?.setModelReady(id != nil)
            guard let id else { return }
            _ = try? await index.search([Float](repeating: 0, count: id.dimension), identity: id, owners: [], limit: 1)
        }
    }

    private func setModelReady(_ ready: Bool) { embeddingModelReady = ready }

    // MARK: - Status

    private struct Status: Sendable {
        var counts: [JobStatus: Int]
        var report: CompactionReport?
        var used: Int
        var backoff: UsageBackoff
        var sizes: (main: Int64, wal: Int64)
        var awaiting: Int?
    }

    /// Reads the status off the main actor. `full` adds the slow `awaitingSummary` count (Settings
    /// appearing, after compaction); a light refresh keeps the last count. A refresh asked for
    /// while one runs is dropped (a full one runs once after it).
    func refreshStatus(full: Bool = false) {
        guard refreshGate.begin(full: full) else { return }
        runRefresh(full: full)
    }

    private func runRefresh(full: Bool) {
        let db = db, calendar = calendar, retention = settings.retention()
        Task { [weak self] in
            let status = await Task.detached(priority: .utility) { () -> Status? in
                let now = Date.now
                do {
                    let settings = SettingsStore(db)
                    var awaiting: Int?
                    if full, case .days(let n) = retention {
                        // Built outside `awaitingSummary`'s read: GRDB reads are not reentrant (T11).
                        // Unloadable exclusions: compaction deletes nothing, so every row counts.
                        let policy = try? CapturePolicy(userRules: ExclusionStore(db).all().compactMap(ExclusionRule.init(pattern:)))
                        awaiting = try RetentionStore(db).awaitingSummary(
                            olderThan: now.addingTimeInterval(-Double(n) * 86_400),
                            isAllowed: { s in policy.map { SnapshotPolicy.allows(s, policy: $0) } ?? true })
                    }
                    return Status(
                        counts: try JobStore(db).counts(),
                        report: try? settings.value(CompactionReport.self, forKey: CompactionPipeline.lastReportKey),
                        used: try BudgetGate(db: db, calendar: calendar).usedToday(now: now),
                        backoff: MemorySettings(settings).backoff(),
                        sizes: DatabaseStats.fileSizes(AppDatabase.defaultURL),
                        awaiting: awaiting)
                } catch {
                    return nil
                }
            }.value
            guard let self else { return }
            defer { if refreshGate.end() { runRefresh(full: true) } }
            guard let status else {
                statusUnreadable = true
                return
            }
            statusUnreadable = false
            counts = status.counts
            lastCompaction = status.report
            budgetUsed = status.used
            backoffUntil = status.backoff.until.flatMap { $0 > .now ? $0 : nil }
            dbSize = status.sizes
            if let awaiting = status.awaiting {
                awaitingSummary = awaiting
            } else if full, case .forever = retention {
                awaitingSummary = 0
            }
            budget = settings.dailyTokenBudget()
        }
    }
}
