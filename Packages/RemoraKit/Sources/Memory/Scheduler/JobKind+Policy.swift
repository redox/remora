import Foundation
import Storage

/// When a job kind may start (plan 4 pinned values).
public enum RunCondition: Sendable, Equatable {
    case anytime
    /// The user has been idle at least this long.
    case idle(TimeInterval)
    /// Idle `idleOnPowerSeconds` and on AC power (Low Power Mode counts as battery).
    case idleOnPower

    public static let idleOnPowerSeconds: TimeInterval = 120

    public func holds(_ s: SchedulerSignals) -> Bool {
        switch self {
        case .anytime: true
        case .idle(let seconds): s.idleSeconds >= seconds
        case .idleOnPower: s.idleSeconds >= Self.idleOnPowerSeconds && s.onPower && !s.lowPower
        }
    }
}

extension JobKind {
    public var runCondition: RunCondition {
        switch self {
        case .workingMemory, .timeLedger, .hour, .dayRollup, .weekRollup, .monthRollup, .yearRollup, .wikiRewrite,
             .morningBrief, .eveningWrap, .nudgeScan, .digestRebuild:
            .anytime
        case .styleNotes, .identity, .routineScan: .idle(120)
        case .embeddings, .compaction: .idleOnPower
        }
    }

    /// False for kinds that never call a cloud model.
    public var mayUseCloud: Bool {
        switch self {
        case .timeLedger, .embeddings, .routineScan: false
        default: true
        }
    }

    /// Kinds that may still use the cloud once the budget passes 80 % (plan 5 adds the briefs and
    /// the digest rebuild after a forget; nudge scans stop).
    static let softBudgetKinds: Set<JobKind> = [.hour, .dayRollup, .workingMemory, .morningBrief, .eveningWrap,
                                                .digestRebuild]

    /// Kinds that always pass the gate and run without the cloud when it is denied (F-8):
    /// working memory falls back to on-device, compaction skips its LLM steps.
    static let alwaysRunKinds: Set<JobKind> = [.workingMemory, .compaction]

    /// How long one run may take before it is cancelled and retried: compaction (many steps,
    /// embeddings, vacuum) 15 minutes, every other kind 300 s.
    public var timeout: Duration {
        self == .compaction ? .seconds(15 * 60) : .seconds(300)
    }

    /// Overdue by this much, compaction drops its power requirement and runs on `.idle(120)`.
    static let compactionOverdue: TimeInterval = 86_400
}

/// Which jobs may run, and whether they may use the cloud, given memory, account, backoff and
/// budget state. Pure, so the whole table is unit-tested.
enum SchedulerGate {
    enum DenyReason: Sendable, Equatable { case disabled, account, backoff, budget }
    enum Decision: Sendable, Equatable {
        case run(cloudAllowed: Bool)
        case deny(DenyReason)
    }

    /// With memory off only `time_ledger` and `compaction` run (without the cloud): briefs and nudge
    /// scans are denied too (no memory, no evidence; addendum B.8).
    static func decide(_ kind: JobKind, memoryEnabled: Bool, accountReady: Bool, backoffAllows: Bool,
                       level: BudgetLevel) -> Decision {
        if !memoryEnabled, kind != .timeLedger, kind != .compaction { return .deny(.disabled) }
        if !kind.mayUseCloud { return .run(cloudAllowed: false) }
        let cloudUsable = memoryEnabled && accountReady && backoffAllows
        if JobKind.alwaysRunKinds.contains(kind) {
            return .run(cloudAllowed: cloudUsable && level != .exhausted)
        }
        if !accountReady { return .deny(.account) }
        if !backoffAllows { return .deny(.backoff) }
        if !BudgetGate.allowsCloud(kind, at: level) { return .deny(.budget) }
        return .run(cloudAllowed: true)
    }
}
