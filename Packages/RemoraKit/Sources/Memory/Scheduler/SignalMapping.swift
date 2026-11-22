import Foundation
import LLM
import Storage

extension SchedulerSignals {
    /// The app's mapping from raw system and account readings to tick signals (F-46).
    /// - `accountReady`: signed in with plan usage enabled (F-44/F-56).
    /// - `onDeviceAvailable`: the on-device model reports `.available`.
    /// - `onPower` is false in Low Power Mode, even plugged in ("low power counts as not on power").
    /// - An idle reading that is negative or not finite counts as active (0 s), never as idle.
    public static func make(account: SignInState, onDevice: OnDeviceAvailability, idle: TimeInterval, power: Bool,
                            lowPower: Bool, memoryEnabled: Bool, now: Date) -> SchedulerSignals {
        var accountReady = false
        if case .signedIn(_, true) = account { accountReady = true }
        return SchedulerSignals(now: now, idleSeconds: idle.isFinite ? max(idle, 0) : 0, onPower: power && !lowPower,
                                lowPower: lowPower, accountReady: accountReady,
                                onDeviceAvailable: onDevice == .available, memoryEnabled: memoryEnabled)
    }
}

/// A tick's signals are read once, when it starts. When the user comes back while a tick planned
/// on idle signals is still running, idle-gated work (`style_notes`, `identity`, `embeddings`,
/// `compaction`) is running or could still be picked on stale signals: the app cancels the tick.
public enum IdleReturn {
    /// Input within this many seconds means the user is back.
    public static let activeSeconds: TimeInterval = 5

    /// True when the tick started idle enough for idle-gated jobs, the user is back, and the
    /// running job (nil between jobs) is not an `.anytime` one (those results stay valid).
    public static func shouldCancel(tickIdleSeconds: TimeInterval, nowIdleSeconds: TimeInterval,
                                    runningKind: JobKind?) -> Bool {
        let idleGatedPossible = JobKind.allCases.contains { kind in
            switch kind.runCondition {
            case .anytime: false
            case .idle(let seconds): tickIdleSeconds >= seconds
            case .idleOnPower: tickIdleSeconds >= RunCondition.idleOnPowerSeconds
            }
        }
        guard idleGatedPossible, nowIdleSeconds < activeSeconds else { return false }
        return runningKind.map { $0.runCondition != .anytime } ?? true
    }
}

/// The app's lifecycle rules for background memory (final review #11, #13), kept here so they are
/// unit-tested; `MemoryController` only wires them to notifications.
public enum MemoryLifecycle {
    /// The vector cache is warmed this long after launch, off the launch path.
    public static let warmIndexDelay: Duration = .seconds(30)

    /// Signing out (account ready → not ready) cancels the running job: it goes back to pending
    /// without an attempt (`MemoryScheduler.cancelCurrent`).
    public static func cancelsOnAccountChange(wasReady: Bool, isReady: Bool) -> Bool { wasReady && !isReady }

    /// Warming loads the embedding model and the vector cache: only worth it with memory on and
    /// the model's assets already on disk (warming never downloads them).
    public static func shouldWarmIndex(memoryEnabled: Bool, modelDownloaded: Bool) -> Bool {
        memoryEnabled && modelDownloaded
    }
}

/// Coalesces Settings status refreshes (final review #12): a refresh asked for while one runs is
/// dropped, except that a full one (with the slow `awaitingSummary` count) asked for during a
/// light one runs once after it.
public struct StatusRefreshGate: Sendable, Equatable {
    public private(set) var inFlight = false
    private var fullQueued = false

    public init() {}

    /// True when the refresh should start now.
    public mutating func begin(full: Bool) -> Bool {
        if inFlight {
            if full { fullQueued = true }
            return false
        }
        inFlight = true
        return true
    }

    /// Ends the running refresh. True when a queued full refresh should start now (the gate stays
    /// in flight for it).
    public mutating func end() -> Bool {
        guard fullQueued else {
            inFlight = false
            return false
        }
        fullQueued = false
        return true
    }
}
