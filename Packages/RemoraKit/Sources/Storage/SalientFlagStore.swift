import CryptoKit
import Foundation
import GRDB

/// Events, emails, commitments and todos seen on screen (`salient_flags`). Open commitments and
/// todos are the user's open loops.
///
/// Writes take the caller's `Database` so a runner can do them inside `DataGeneration.write`
/// (GRDB writes are not reentrant). Callers redact LLM output before storing it.
public struct SalientFlagStore: Sendable {
    private let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    /// `kind|` + the first 16 hex digits of SHA-256 over the `TextFold.key` of the text and of the
    /// person: the same flag worded with other case, accents, punctuation or spacing shares a key.
    /// The key never holds the text itself.
    public static func dedupeKey(kind: FlagKind, text: String, person: String) -> String {
        let material = TextFold.key(text) + "\u{1F}" + TextFold.key(person)
        let digest = SHA256.hash(data: Data(material.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return kind.rawValue + "|" + digest
    }

    public static func flag(dedupeKey: String, in d: Database) throws -> SalientFlag? {
        try SalientFlag.fetchOne(d, sql: "SELECT * FROM salient_flags WHERE dedupe_key = ?", arguments: [dedupeKey])
    }

    /// Inserts `f`, or merges it into the row with the same `dedupe_key`: `last_seen_at` moves
    /// forward only, snapshot ids are unioned (existing first), a missing due date or call id is
    /// filled; status, text, quote and creation time are kept. Returns the stored row.
    @discardableResult
    public func upsert(_ f: SalientFlag, in d: Database) throws -> SalientFlag {
        try Self.upsert(f, in: d)
    }

    @discardableResult
    public static func upsert(_ f: SalientFlag, in d: Database) throws -> SalientFlag {
        guard var row = try flag(dedupeKey: f.dedupeKey, in: d) else {
            var new = f
            new.id = nil
            try new.insert(d)
            return new
        }
        row.lastSeenAt = max(row.lastSeenAt, f.lastSeenAt)
        row.snapshotIDs = Self.union(row.snapshotIDs, f.snapshotIDs)
        row.dueAt = row.dueAt ?? f.dueAt
        row.llmCallID = row.llmCallID ?? f.llmCallID
        try row.update(d)
        return row
    }

    /// Open flags of `kinds`: dated ones first (soonest due), then the most recently seen.
    public func open(kinds: Set<FlagKind>, limit: Int) throws -> [SalientFlag] {
        guard !kinds.isEmpty, limit > 0 else { return [] }
        let names = kinds.map(\.rawValue).sorted()
        let marks = Array(repeating: "?", count: names.count).joined(separator: ",")
        var arguments = StatementArguments(names)
        arguments += [limit]
        return try db.reader.read { d in
            try SalientFlag.fetchAll(d, sql: """
                SELECT * FROM salient_flags WHERE status = 'open' AND kind IN (\(marks))
                ORDER BY due_at IS NULL, due_at, last_seen_at DESC, id DESC LIMIT ?
                """, arguments: arguments)
        }
    }

    /// Open flags due before `now + within`, overdue ones included, soonest first.
    public func dueSoon(within: TimeInterval, now: Date, limit: Int) throws -> [SalientFlag] {
        try db.reader.read { d in
            try SalientFlag.fetchAll(d, sql: """
                SELECT * FROM salient_flags WHERE status = 'open' AND due_at IS NOT NULL AND due_at <= ?
                ORDER BY due_at, id LIMIT ?
                """, arguments: [now.addingTimeInterval(within), limit])
        }
    }

    /// Records a check: the new status, `checked_at = at`, `closed_at = at` unless the flag stays
    /// open (nil then), the closing evidence unioned, and the confidence when given.
    public func setStatus(id: Int64, _ s: FlagStatus, closeSnapshotIDs: [Int64], confidence: Double?, at: Date) throws {
        try db.writer.write { d in
            try Self.setStatus(id: id, s, closeSnapshotIDs: closeSnapshotIDs, confidence: confidence, at: at, in: d)
        }
    }

    public static func setStatus(id: Int64, _ s: FlagStatus, closeSnapshotIDs: [Int64], confidence: Double?, at: Date,
                                 in d: Database) throws {
        guard var row = try SalientFlag.fetchOne(d, key: id) else { return }
        row.status = s
        row.checkedAt = at
        row.closedAt = s == .open ? nil : at
        row.closeSnapshotIDs = Self.union(row.closeSnapshotIDs, closeSnapshotIDs)
        if let confidence { row.confidence = confidence }
        try row.update(d)
    }

    static func union(_ a: [Int64], _ b: [Int64]) -> [Int64] {
        var seen = Set<Int64>()
        return (a + b).filter { seen.insert($0).inserted }
    }
}
