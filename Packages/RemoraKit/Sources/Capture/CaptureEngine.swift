import CryptoKit
import Foundation
import os
import Redaction
import Storage
import Synchronization

public protocol WindowReading: Sendable {
    func readFrontmost() async throws -> (context: WindowContext, text: String)?
    /// Reads the context, and extracts text only when `policy` allows that context, so the
    /// text of excluded apps/windows never enters the process.
    func readFrontmost(policy: CapturePolicy) async throws -> (context: WindowContext, text: String)?
}

extension WindowReading {
    /// Fallback for readers that cannot check before extracting: drops disallowed text.
    public func readFrontmost(policy: CapturePolicy) async throws -> (context: WindowContext, text: String)? {
        guard let (context, text) = try await readFrontmost() else { return nil }
        return (context, policy.shouldCapture(context) ? text : "")
    }
}

public enum CaptureOutcome: Sendable, Equatable {
    case paused, noWindow, excluded, tooShort, unchanged, timedOut, stored(Int64), failed
}

public actor CaptureEngine {
    /// Clipboard text is cut to this many characters (prefix) before redaction.
    public static let clipboardCharLimit = 50_000

    private let reader: any WindowReading
    private let snapshots: SnapshotStore
    private let activity: ActivityStore
    private let settings: SettingsStore
    private let exclusions: ExclusionStore
    private let redactor: Redactor
    private let readTimeout: Duration
    private let minChars: Int
    private let now: @Sendable () -> Date
    private let logger = Logger(subsystem: "dev.remora", category: "capture")
    private var readInFlight = false
    private let boilerplate: BoilerplateStore
    private let db: AppDatabase
    private let boilerplateLogger = Logger(subsystem: "dev.remora", category: "boilerplate")
    /// Data generation the caches below belong to; a delete-all bumps it.
    private var cacheGeneration: Int?
    private static let maxSampledLines = 2_000
    /// Learned hashes per surface, refreshed at most every `learnedTTL`: no store read per tick.
    private var learnedCache: [String: (hashes: Set<String>, at: Date)] = [:]
    private var knownFitted: Set<String> = []
    private static let learnedTTL: TimeInterval = 60

    public init(reader: any WindowReading, db: AppDatabase, redactor: Redactor = .init(),
                readTimeout: Duration = .milliseconds(500), minChars: Int = 20,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.reader = reader
        self.snapshots = SnapshotStore(db)
        self.activity = ActivityStore(db)
        self.settings = SettingsStore(db)
        self.exclusions = ExclusionStore(db)
        self.boilerplate = BoilerplateStore(db)
        self.db = db
        self.redactor = redactor
        self.readTimeout = readTimeout
        self.minChars = minChars
        self.now = now
    }

    public func tick() async -> CaptureOutcome {
        if let early = pauseOutcome() { return early }
        // A previous read is still hung: do not stack another one behind it.
        if readInFlight { return .timedOut }

        // User exclusions go into the reader's policy so excluded apps are never walked. If
        // they cannot be loaded, nothing is walked (fail closed).
        let policy: CapturePolicy
        do { policy = try currentPolicy() } catch {
            log("exclusions load failed", error)
            policy = .denyAll
        }

        readInFlight = true
        let read = await race(policy: policy)
        if case .timedOut = read { return .timedOut }  // flag cleared when the abandoned read ends
        readInFlight = false

        let value: (context: WindowContext, text: String)?
        switch read {
        case .value(let v): value = v
        case .failed: return .failed
        case .timedOut: return .timedOut
        }
        guard let (context, text) = value else { return .noWindow }
        // Pause may have been engaged while the read was in progress.
        if let late = pauseOutcome() { return late }

        // Re-checked with freshly loaded rules: a rule added during the read still applies.
        let allowed: Bool
        do { allowed = try isAllowed(context) } catch {
            log("exclusions load failed", error)
            recordFocus(context, full: false)
            return .excluded
        }
        // Excluded contexts: time tracking only, with no title/domain (those are content).
        recordFocus(context, full: allowed)
        guard allowed else { return .excluded }
        return store(text: text, context: context, source: .ax)
    }

    public func storeClipboard(text: String, context: WindowContext) async -> CaptureOutcome {
        if let early = pauseOutcome() { return early }
        do { guard try isAllowed(context) else { return .excluded } } catch {
            log("exclusions load failed", error)
            return .excluded
        }
        let capped = String(text.prefix(Self.clipboardCharLimit))
        return store(text: capped, context: context, source: .clipboard)
    }

    private func readFinished() { readInFlight = false }

    private func log(_ what: String, _ error: any Error) {
        logger.error("\(what, privacy: .public): \(String(describing: type(of: error)), privacy: .public)")
    }

    /// Privacy controls fail closed: an unreadable pause state counts as paused.
    private func pauseOutcome() -> CaptureOutcome? {
        do { return try settings.isPaused(now: now()) ? .paused : nil } catch {
            log("pause state unreadable", error)
            return .paused
        }
    }

    /// Titles and URLs are content: they go through the same redaction as captured text before
    /// any write. The domain comes from the real host (needed for exclusions and time tracking).
    private func redactedTitle(_ context: WindowContext) -> String? {
        context.windowTitle.map(redactor.redact)
    }

    private func redactedURL(_ context: WindowContext) -> String? {
        context.url.map { redactor.redact($0.absoluteString) }
    }

    private func recordFocus(_ context: WindowContext, full: Bool) {
        do {
            let at = now()
            try activity.recordFocus(
                app: context.app, bundleID: context.bundleID,
                windowTitle: full ? redactedTitle(context) : nil,
                domain: full ? context.domain : nil, at: at, unlessPausedAt: at)
        } catch { log("recordFocus failed", error) }
    }

    // MARK: - Pipeline

    private func currentPolicy() throws -> CapturePolicy {
        CapturePolicy(userRules: try exclusions.all().compactMap(ExclusionRule.init(pattern:)))
    }

    /// The capture verdict for a context under freshly loaded rules. Ignores pause; a rules
    /// load failure fails closed as `.rulesUnavailable`.
    public func verdict(for context: WindowContext) -> CaptureVerdict {
        do { return try currentPolicy().verdict(context) } catch {
            log("exclusions load failed", error)
            return .rulesUnavailable
        }
    }

    /// The app-level verdict (no window info) under freshly loaded rules, for the moment an app
    /// activates, before its first context sample. Fails closed like `verdict(for:)`.
    public func appVerdict(for context: WindowContext) -> CaptureVerdict {
        do { return try currentPolicy().appVerdict(context) } catch {
            log("exclusions load failed", error)
            return .rulesUnavailable
        }
    }

    private func isAllowed(_ context: WindowContext) throws -> Bool {
        try currentPolicy().shouldCapture(context)
    }

    private func logBoilerplate(_ what: String, _ error: any Error) {
        boilerplateLogger.error("\(what, privacy: .public): \(String(describing: type(of: error)), privacy: .public)")
    }

    /// Drops the caches when a delete-all (generation bump) happened, or the generation is unreadable.
    private func syncCacheGeneration() {
        let current = try? DataGeneration.current(db)
        if current == nil || current != cacheGeneration {
            learnedCache.removeAll()
            knownFitted.removeAll()
            cacheGeneration = current
        }
    }

    /// Learned interface lines of a surface, cached briefly. A read failure logs and yields none
    /// (text is then stored unstripped).
    private func learnedHashes(_ surface: String) -> Set<String> {
        let at = now()
        if let c = learnedCache[surface], at.timeIntervalSince(c.at) < Self.learnedTTL, at >= c.at { return c.hashes }
        do {
            let hashes = try boilerplate.learned(surface: surface)
            if learnedCache.count >= 64 { learnedCache.removeAll() }
            learnedCache[surface] = (hashes, at)
            return hashes
        } catch { logBoilerplate("boilerplate read failed", error); return [] }
    }

    /// First fit when a surface reaches 20 documents; failures log and never affect capture.
    private func fitIfNeeded(_ surface: String) {
        guard !knownFitted.contains(surface) else { return }
        do {
            if try boilerplate.isFitted(surface: surface) { knownFitted.insert(surface); return }
            guard try boilerplate.surfacesNeedingFirstFit().contains(surface) else { return }
            try boilerplate.refresh(surface: surface, at: now())
            learnedCache[surface] = nil
            knownFitted.insert(surface)
        } catch { logBoilerplate("boilerplate fit failed", error) }
    }

    private func store(text: String, context: WindowContext, source: SnapshotSource) -> CaptureOutcome {
        let surface = BoilerplateSurface.key(bundleID: context.bundleID, app: context.app, domain: context.domain)
        let isAX = source == .ax
        // Redact FIRST: a label line ("Password:") must still see its value on the next line.
        // Learned lines are redaction-invariant, so stripping the redacted text removes the same
        // lines. Clipboard text is never stripped or sampled.
        var redacted = redactor.redact(text)
        let rawRedacted = redacted
        if isAX {
            syncCacheGeneration()
            redacted = BoilerplateStripper.strip(redacted, learned: learnedHashes(surface))
        }
        guard redacted.trimmingCharacters(in: .whitespacesAndNewlines).count >= minChars else {
            return .tooShort
        }
        let hash = Self.hash(redacted)
        let title = redactedTitle(context)
        do {
            let previous = try snapshots.latestHash(
                app: context.app, windowTitle: title, source: source)
            if previous == hash { return .unchanged }
        } catch { log("dedupe lookup failed", error); return .failed }

        // Sampled only for a changed document, from the RAW text and its whole-text redaction.
        var sample: BoilerplateSample?
        if isAX, text.utf8.count < 400_000 {
            sample = BoilerplateSample.sample(surface: surface, text: text, redacted: rawRedacted,
                                              maxInputLines: Self.maxSampledLines)
        }

        let snapshot = Snapshot(
            capturedAt: now(), app: context.app, bundleID: context.bundleID,
            windowTitle: title, url: redactedURL(context),
            domain: context.domain, filePath: context.filePath,
            text: redacted, contentHash: hash, source: source)
        do {
            // Pause check + write in one transaction: nothing lands after a delete-all's pause.
            // A continuation of the window's recent snapshot updates it in place (rolling).
            guard let stored = try snapshots.upsertUnlessPaused(snapshot, now: now(), sample: sample) else { return .paused }
            guard let id = stored.id else { return .failed }
            if isAX { fitIfNeeded(surface) }
            return .stored(id)
        } catch { log("insert failed", error); return .failed }
    }

    static func hash(_ redacted: String) -> String {
        let normalized = redacted.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Timeout race

    private enum ReadResult: Sendable {
        case value((context: WindowContext, text: String)?)
        case failed
        case timedOut
    }

    /// First-wins gate: resumes the continuation exactly once; later resolutions are dropped.
    private final class Gate: Sendable {
        private struct State {
            var continuation: CheckedContinuation<ReadResult, Never>?
            var timer: Task<Void, Never>?
            var read: Task<Void, Never>?
        }
        private let state = Mutex(State())
        func arm(_ c: CheckedContinuation<ReadResult, Never>) { state.withLock { $0.continuation = c } }
        func attach(timer: Task<Void, Never>, read: Task<Void, Never>) {
            state.withLock { $0.timer = timer; $0.read = read }
        }
        /// Returns true if this call won the race. The loser's task is cancelled/abandoned.
        @discardableResult
        func resolve(_ r: ReadResult) -> Bool {
            let (c, timer, read) = state.withLock { s in
                defer { s = State() }
                return (s.continuation, s.timer, s.read)
            }
            guard let c else { return false }
            if case .timedOut = r { read?.cancel() } else { timer?.cancel() }
            c.resume(returning: r)
            return true
        }
    }

    /// Races the read against a timer in detached unstructured tasks. On timeout the read task
    /// is cancelled and abandoned: never awaited, its late result discarded by the gate, so a hung
    /// reader cannot block the actor or write anything. It hops back to clear `readInFlight`.
    private func race(policy: CapturePolicy) async -> ReadResult {
        let reader = self.reader, timeout = self.readTimeout
        return await withCheckedContinuation { (continuation: CheckedContinuation<ReadResult, Never>) in
            let gate = Gate()
            gate.arm(continuation)
            let readTask = Task.detached { [weak self] in
                let result: ReadResult
                do { result = .value(try await reader.readFrontmost(policy: policy)) } catch { result = .failed }
                if !gate.resolve(result) { await self?.readFinished() }
            }
            let timerTask = Task.detached {
                do { try await Task.sleep(for: timeout) } catch { return }
                gate.resolve(.timedOut)
            }
            gate.attach(timer: timerTask, read: readTask)
        }
    }
}
