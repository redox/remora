import Foundation
import GRDB

/// A job the planner wants: one row per `(kind, periodKey)`, due at `notBefore`.
public struct JobSpec: Sendable, Equatable {
    public var kind: JobKind
    public var periodKey: String
    public var periodStart: Date?
    public var periodEnd: Date?
    public var notBefore: Date

    public init(kind: JobKind, periodKey: String, periodStart: Date? = nil, periodEnd: Date? = nil, notBefore: Date) {
        self.kind = kind; self.periodKey = periodKey; self.periodStart = periodStart
        self.periodEnd = periodEnd; self.notBefore = notBefore
    }
}

/// The persistent background job queue (`jobs`).
///
/// Every method has an `in d: Database` form so a runner can update job rows inside
/// `DataGeneration.write` (GRDB writes are not reentrant); the plain forms open their own
/// transaction and forward. `last_error` only ever receives error codes.
public struct JobStore: Sendable {
    /// A job is `failed` once this many attempts were retried.
    public static let maxAttempts = 6

    private let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    /// `min(5 min · 2^(attempts−1), 6 h)` (plan 4 pinned values).
    public static func retryDelay(afterAttempt attempts: Int) -> TimeInterval {
        let exponent = min(max(attempts - 1, 0), 16)
        return min(300 * pow(2, Double(exponent)), 21_600)
    }

    // MARK: Writes

    /// INSERT OR IGNORE per `(kind, period_key)`; returns how many rows were inserted.
    @discardableResult
    public func enqueue(_ specs: [JobSpec], now: Date) throws -> Int {
        try db.writer.write { d in try enqueue(specs, now: now, in: d) }
    }

    @discardableResult
    public func enqueue(_ specs: [JobSpec], now: Date, in d: Database) throws -> Int {
        var inserted = 0
        for s in specs {
            try d.execute(sql: """
                INSERT OR IGNORE INTO jobs (kind, period_key, period_start, period_end, status, priority,
                                            attempts, next_run_at, created_at, updated_at)
                VALUES (?, ?, ?, ?, 'pending', ?, 0, ?, ?, ?)
                """, arguments: [s.kind.rawValue, s.periodKey, s.periodStart, s.periodEnd, s.kind.priority,
                                 s.notBefore, now, now])
            inserted += d.changesCount
        }
        return inserted
    }

    /// Pending jobs of `kind` whose period starts before `start` become `skipped` (reason
    /// `superseded`): a newer slot replaces them (working memory). Returns how many.
    @discardableResult
    public func skipPending(kind: JobKind, startingBefore start: Date, now: Date, in d: Database) throws -> Int {
        try d.execute(sql: """
            UPDATE jobs SET status = 'skipped', last_error = 'superseded', updated_at = ?
            WHERE kind = ? AND status = 'pending' AND period_start < ?
            """, arguments: [now, kind.rawValue, start])
        return d.changesCount
    }

    /// Deletes finished jobs (`done`, `skipped`, `failed`) last updated before `cutoff`, except an
    /// hour job whose chronicle is dirty (the planner requeues it). Returns how many.
    @discardableResult
    public static func pruneFinished(before cutoff: Date, in d: Database) throws -> Int {
        try d.execute(sql: """
            DELETE FROM jobs WHERE status IN ('done', 'skipped', 'failed') AND updated_at < ?
              AND NOT (kind = 'hour' AND EXISTS (
                  SELECT 1 FROM chronicle c WHERE c.level = 'hour' AND c.period_key = jobs.period_key AND c.is_dirty = 1))
            """, arguments: [cutoff])
        return d.changesCount
    }

    /// Any status back to `pending`, attempts 0, due now. No-op when the job does not exist.
    public func requeue(kind: JobKind, periodKey: String, now: Date) throws {
        try db.writer.write { d in try requeue(kind: kind, periodKey: periodKey, now: now, in: d) }
    }

    public func requeue(kind: JobKind, periodKey: String, now: Date, in d: Database) throws {
        try d.execute(sql: """
            UPDATE jobs SET status = 'pending', attempts = 0, next_run_at = ?, last_error = NULL, updated_at = ?
            WHERE kind = ? AND period_key = ?
            """, arguments: [now, now, kind.rawValue, periodKey])
    }

    /// Like `requeue`, but only when the job's status is one of `statuses` (e.g. a finished
    /// rollup, never a running or failed one). Returns whether the job was requeued.
    @discardableResult
    public func requeue(kind: JobKind, periodKey: String, now: Date, ifStatusIn statuses: Set<JobStatus>,
                        in d: Database) throws -> Bool {
        guard !statuses.isEmpty else { return false }
        let names = statuses.map(\.rawValue).sorted()
        let marks = Array(repeating: "?", count: names.count).joined(separator: ",")
        var arguments: StatementArguments = [now, now, kind.rawValue, periodKey]
        arguments += StatementArguments(names)
        try d.execute(sql: """
            UPDATE jobs SET status = 'pending', attempts = 0, next_run_at = ?, last_error = NULL, updated_at = ?
            WHERE kind = ? AND period_key = ? AND status IN (\(marks))
            """, arguments: arguments)
        return d.changesCount > 0
    }

    public func markRunning(id: Int64, now: Date) throws {
        try db.writer.write { d in try markRunning(id: id, now: now, in: d) }
    }

    public func markRunning(id: Int64, now: Date, in d: Database) throws {
        try d.execute(sql: "UPDATE jobs SET status = 'running', updated_at = ? WHERE id = ?", arguments: [now, id])
    }

    /// Sets a final status. `reason` (a skip or error code, never content) goes to `last_error`.
    /// `ifRunning`: only while the row is still `running`, so a requeue made during the run wins.
    public func complete(id: Int64, status: JobStatus, reason: String? = nil, now: Date, ifRunning: Bool = false) throws {
        try db.writer.write { d in
            try complete(id: id, status: status, reason: reason, now: now, ifRunning: ifRunning, in: d)
        }
    }

    public func complete(id: Int64, status: JobStatus, reason: String? = nil, now: Date, ifRunning: Bool = false,
                         in d: Database) throws {
        try d.execute(sql: "UPDATE jobs SET status = ?, last_error = ?, updated_at = ? WHERE id = ?" + Self.guardSQL(ifRunning),
                      arguments: [status.rawValue, reason, now, id])
    }

    /// Counts an attempt: back to `pending` after `retryDelay`, or `failed` at `maxAttempts`.
    /// `error` is an error code only.
    public func retry(id: Int64, error: String, now: Date, ifRunning: Bool = false) throws {
        try db.writer.write { d in try retry(id: id, error: error, now: now, ifRunning: ifRunning, in: d) }
    }

    public func retry(id: Int64, error: String, now: Date, ifRunning: Bool = false, in d: Database) throws {
        guard let previous = try Int.fetchOne(d, sql: "SELECT attempts FROM jobs WHERE id = ?" + Self.guardSQL(ifRunning),
                                              arguments: [id])
        else { return }
        let attempts = previous + 1
        let failed = attempts >= Self.maxAttempts
        try d.execute(sql: """
            UPDATE jobs SET attempts = ?, status = ?, next_run_at = ?, last_error = ?, updated_at = ? WHERE id = ?
            """, arguments: [attempts, failed ? JobStatus.failed.rawValue : JobStatus.pending.rawValue,
                             failed ? now : now.addingTimeInterval(Self.retryDelay(afterAttempt: attempts)),
                             error, now, id])
    }

    /// Back to `pending` until `until`, without counting an attempt (usage limit, account state,
    /// cancellation). `reason` is an error code; nil keeps the previous one.
    public func postpone(id: Int64, until: Date, reason: String? = nil, ifRunning: Bool = false) throws {
        try db.writer.write { d in try postpone(id: id, until: until, reason: reason, ifRunning: ifRunning, in: d) }
    }

    public func postpone(id: Int64, until: Date, reason: String? = nil, ifRunning: Bool = false,
                         in d: Database) throws {
        try d.execute(sql: """
            UPDATE jobs SET status = 'pending', next_run_at = ?, last_error = COALESCE(?, last_error) WHERE id = ?
            """ + Self.guardSQL(ifRunning), arguments: [until, reason, id])
    }

    private static func guardSQL(_ ifRunning: Bool) -> String { ifRunning ? " AND status = 'running'" : "" }

    /// At launch: jobs left `running` by a crash or quit go back to `pending` (no attempt).
    @discardableResult
    public func resetRunning(now: Date) throws -> Int {
        try db.writer.write { d in try resetRunning(now: now, in: d) }
    }

    @discardableResult
    public func resetRunning(now: Date, in d: Database) throws -> Int {
        try d.execute(sql: "UPDATE jobs SET status = 'pending', updated_at = ? WHERE status = 'running'",
                      arguments: [now])
        return d.changesCount
    }

    // MARK: Reads

    /// The next pending job due by `now` among `kinds`: lowest priority, then oldest period, then id.
    public func nextDue(now: Date, kinds: Set<JobKind>) throws -> Job? {
        try db.reader.read { d in try nextDue(now: now, kinds: kinds, in: d) }
    }

    public func nextDue(now: Date, kinds: Set<JobKind>, in d: Database) throws -> Job? {
        guard !kinds.isEmpty else { return nil }
        let names = kinds.map(\.rawValue).sorted()
        let marks = Array(repeating: "?", count: names.count).joined(separator: ",")
        var arguments: StatementArguments = [now]
        arguments += StatementArguments(names)
        return try Job.fetchOne(d, sql: """
            SELECT * FROM jobs WHERE status = 'pending' AND next_run_at <= ? AND kind IN (\(marks))
            ORDER BY priority, period_start, id LIMIT 1
            """, arguments: arguments)
    }

    public func job(kind: JobKind, periodKey: String) throws -> Job? {
        try db.reader.read { d in try job(kind: kind, periodKey: periodKey, in: d) }
    }

    public func job(kind: JobKind, periodKey: String, in d: Database) throws -> Job? {
        try Job.fetchOne(d, sql: "SELECT * FROM jobs WHERE kind = ? AND period_key = ?",
                         arguments: [kind.rawValue, periodKey])
    }

    public func status(kind: JobKind, periodKey: String) throws -> JobStatus? {
        try job(kind: kind, periodKey: periodKey)?.status
    }

    public func status(kind: JobKind, periodKey: String, in d: Database) throws -> JobStatus? {
        try job(kind: kind, periodKey: periodKey, in: d)?.status
    }

    /// Jobs of `kind` whose `[period_start, period_end)` overlaps `interval` (rows without a
    /// period never match), oldest first. The planner uses it because hour jobs are keyed by
    /// merged span, not by hour (F-5).
    public func jobs(kind: JobKind, overlapping interval: DateInterval) throws -> [Job] {
        try db.reader.read { d in try jobs(kind: kind, overlapping: interval, in: d) }
    }

    public func jobs(kind: JobKind, overlapping interval: DateInterval, in d: Database) throws -> [Job] {
        try Job.fetchAll(d, sql: """
            SELECT * FROM jobs WHERE kind = ? AND period_start < ? AND period_end > ? ORDER BY period_start, id
            """, arguments: [kind.rawValue, interval.end, interval.start])
    }

    public func counts() throws -> [JobStatus: Int] {
        try db.reader.read { d in try counts(in: d) }
    }

    public func counts(in d: Database) throws -> [JobStatus: Int] {
        var result: [JobStatus: Int] = [:]
        for row in try Row.fetchAll(d, sql: "SELECT status, COUNT(*) AS n FROM jobs GROUP BY status") {
            if let status = JobStatus(rawValue: row["status"]) { result[status] = row["n"] }
        }
        return result
    }
}
