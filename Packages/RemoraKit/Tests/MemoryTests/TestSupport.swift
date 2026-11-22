import Foundation
import Synchronization
import Storage
@testable import Memory

let paris: Calendar = {
    var c = Calendar(identifier: .iso8601)
    c.timeZone = TimeZone(identifier: "Europe/Paris")!
    return c
}()

func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
    paris.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

/// Friday 2026-11-20 14:00 in Paris.
let t0 = date(2026, 11, 20, 14)

func signals(now: Date = t0, idle: TimeInterval = 300, onPower: Bool = true, lowPower: Bool = false,
             account: Bool = true, onDevice: Bool = true, enabled: Bool = true) -> SchedulerSignals {
    SchedulerSignals(now: now, idleSeconds: idle, onPower: onPower, lowPower: lowPower, accountReady: account,
                     onDeviceAvailable: onDevice, memoryEnabled: enabled)
}

/// A settable clock for `MemoryScheduler(now:)`. Fixed unless a test advances it.
final class TestClock: Sendable {
    private let date: Mutex<Date>
    init(_ d: Date = t0) { date = Mutex(d) }
    func now() -> Date { date.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { date.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

/// Records every call; `behavior` decides the outcome.
final class FakeRunner: JobRunner {
    typealias Behavior = @Sendable (Job, JobContext) async throws -> JobOutcome
    private let behavior: Behavior
    private let log = Mutex<[(Job, JobContext)]>([])

    init(_ behavior: @escaping Behavior = { _, _ in .done }) { self.behavior = behavior }

    func run(_ job: Job, context: JobContext) async throws -> JobOutcome {
        log.withLock { $0.append((job, context)) }
        return try await behavior(job, context)
    }

    var calls: [(job: Job, context: JobContext)] { log.withLock { $0.map { (job: $0.0, context: $0.1) } } }
    var kinds: [JobKind] { calls.map(\.job.kind) }
}

func runners(_ r: FakeRunner, for kinds: [JobKind] = JobKind.allCases) -> [JobKind: any JobRunner] {
    Dictionary(uniqueKeysWithValues: kinds.map { ($0, r as any JobRunner) })
}

/// Due at `notBefore` (default t0 − 1 h). Hours get distinct period starts so the order is stable.
@discardableResult
func enqueue(_ db: AppDatabase, _ kind: JobKind, _ key: String, start: Date? = nil,
             notBefore: Date = t0.addingTimeInterval(-3_600)) throws -> Job {
    _ = try JobStore(db).enqueue([JobSpec(kind: kind, periodKey: key, periodStart: start,
                                          periodEnd: start?.addingTimeInterval(3_600), notBefore: notBefore)],
                                 now: notBefore)
    return try require(try JobStore(db).job(kind: kind, periodKey: key))
}

func hourKeys(_ n: Int) -> [String] { (0..<n).map { "2026-11-20T0\($0)+0100" } }

/// Inserts a background cloud call row worth `tokens` uncached tokens.
func seedUsage(_ db: AppDatabase, tokens: Int, at: Date = t0.addingTimeInterval(-60),
               job: String = "hour_chronicle", backend: String = "siwc",
               status: LLMCallStatus = .completed) throws {
    _ = try LLMCallStore(db).insert(LLMCall(startedAt: at, durationMs: 100, backend: backend, model: "gpt-6-luna",
                                            jobType: job, status: status, inputTokens: tokens))
}

struct LeakyError: Error, CustomStringConvertible {
    var description: String { "model said: the secret plan" }
}

struct CodedFailure: CodedError { var code: String { "schema_drift" } }

private enum TestError: Error { case missing }
func require<T>(_ v: T?) throws -> T {
    guard let v else { throw TestError.missing }
    return v
}
