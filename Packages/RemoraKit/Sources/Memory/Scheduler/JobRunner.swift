import Foundation
import Storage

/// What a runner gets for one job.
public struct JobContext: Sendable {
    public var now: Date
    public var calendar: Calendar
    /// `DataGeneration` read before the job started: every write goes through
    /// `DataGeneration.write(db, expected: generation)` so a delete-all in between refuses it.
    public var generation: Int
    /// False: no cloud call (on-device only, fail closed, or skip the LLM step).
    public var cloudAllowed: Bool
    public var language: MemoryLanguage

    public init(now: Date, calendar: Calendar, generation: Int, cloudAllowed: Bool, language: MemoryLanguage) {
        self.now = now; self.calendar = calendar; self.generation = generation
        self.cloudAllowed = cloudAllowed; self.language = language
    }
}

public enum JobOutcome: Sendable, Equatable {
    case done
    /// Nothing to do; the string is a code (e.g. `no_evidence`), never content. It is stored in
    /// `jobs.last_error`.
    case skipped(String)
}

/// Runs one kind of job. Throwing `LLMError` lets the scheduler apply the usage backoff or
/// postpone the job; `DataGeneration.Stale` means the result was discarded after a delete-all.
public protocol JobRunner: Sendable {
    func run(_ job: Job, context: JobContext) async throws -> JobOutcome
}

/// A job to put back to `pending`.
public struct JobRef: Sendable, Equatable {
    public var kind: JobKind
    public var periodKey: String
    /// When set, the requeue applies only while the job's status is one of these, checked in the
    /// scheduler's commit (`JobStore.requeue(…, ifStatusIn:)`), so a job that started running or
    /// finished differently since planning is left alone.
    public var ifStatusIn: Set<JobStatus>?
    public init(kind: JobKind, periodKey: String, ifStatusIn: Set<JobStatus>? = nil) {
        self.kind = kind; self.periodKey = periodKey; self.ifStatusIn = ifStatusIn
    }
}

/// What a planner wants done. The planner performs no writes: the scheduler commits the specs, the
/// watermark and the requeues in one generation-checked transaction.
public struct JobPlan: Sendable, Equatable {
    public var specs: [JobSpec]
    /// The new `memory.plannerWatermark`, when it advances.
    public var watermark: Date?
    public var requeues: [JobRef]

    public init(specs: [JobSpec] = [], watermark: Date? = nil, requeues: [JobRef] = []) {
        self.specs = specs; self.watermark = watermark; self.requeues = requeues
    }
}

/// Decides which jobs should exist (plan 4 Task 3's `JobPlanner` conforms). Called at the start
/// of every tick; the specs are enqueued idempotently.
public protocol JobPlanning: Sendable {
    func plan(_ s: SchedulerSignals) throws -> JobPlan
}

/// An error that names itself with a stable code. `jobs.last_error` stores this code (or the
/// error's type name) and never an error's description, which could hold model output (F-60).
public protocol CodedError: Error {
    var code: String { get }
}
