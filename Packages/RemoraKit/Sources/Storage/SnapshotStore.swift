import Foundation
import GRDB
import os

public struct SnapshotStore: Sendable {
    private let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    public func insert(_ s: Snapshot) throws -> Snapshot {
        try db.writer.write { d in
            var copy = s
            try copy.insert(d)
            return copy
        }
    }

    /// Reads the pause setting and inserts in ONE write transaction (writes are serialised), so a
    /// delete-all that set a pause first can never be followed by an insert. Returns nil when
    /// paused; a corrupt pause value counts as paused.
    public func insertUnlessPaused(_ s: Snapshot, now: Date) throws -> Snapshot? {
        try db.writer.write { d in
            if try SettingsStore.isPausedFailClosed(d, now: now) { return nil }
            var copy = s
            try copy.insert(d)
            return copy
        }
    }

    // MARK: Rolling per-window snapshot

    /// An `.ax` row CREATED at most this long ago can be updated in place by its growth. The
    /// bound is on `first_captured_at` (creation), not `captured_at` (last update), so a
    /// continuously changing window cannot roll into one row forever.
    public static let rollingWindow: TimeInterval = 10 * 60
    /// Share of the old row's distinct non-empty normalised lines that must reappear in the
    /// new text: near-pure growth only. A scrolling viewport (lines dropped at the top) or a
    /// conversation switch behind a large static sidebar falls below it and gets a new row,
    /// so content that scrolled away is never overwritten.
    public static let continuationThreshold = 0.98

    /// Latest `.ax` snapshot of one (app, window title, domain) within the rolling window.
    /// Ordered by the v2 index; the time bound keeps the domain filter to recent rows.
    static let rollingCandidateSQL = """
        SELECT * FROM snapshots
        WHERE app = ? AND window_title IS ? AND source = 'ax' AND captured_at >= ? AND domain IS ?
        ORDER BY captured_at DESC, id DESC LIMIT 1
        """

    /// Like `insertUnlessPaused`, but an `.ax` snapshot that grows the latest `.ax` snapshot
    /// of the same (app, window title, domain), when that row was created at most
    /// `rollingWindow` before `now`, replaces it in place: text, hash, URL, file path and
    /// `captured_at` are updated; the id and `first_captured_at` are kept, and the FTS index
    /// follows through the external-content triggers. A growing chat or document is then one row with its latest text instead of
    /// one near-duplicate row per change. Clipboard snapshots never roll. The pause check and
    /// the write share one transaction. Returns the stored row, or nil when paused.
    public func upsertUnlessPaused(_ s: Snapshot, now: Date) throws -> Snapshot? {
        try upsertUnlessPaused(s, now: now, sample: nil)
    }

    /// As above; `sample` is recorded in the SAME transaction and only when a NEW row is
    /// inserted (a rolled update is the same document).
    public func upsertUnlessPaused(_ s: Snapshot, now: Date, sample: BoilerplateSample?) throws -> Snapshot? {
        try db.writer.write { d in
            if try SettingsStore.isPausedFailClosed(d, now: now) { return nil }
            if s.source == .ax,
               var previous = try Snapshot.fetchOne(d, sql: Self.rollingCandidateSQL, arguments: [
                   s.app, s.windowTitle, now.addingTimeInterval(-Self.rollingWindow), s.domain]),
               now.timeIntervalSince(previous.firstCapturedAt ?? previous.capturedAt) <= Self.rollingWindow,
               Self.continues(old: previous.text, new: s.text) {
                previous.firstCapturedAt = previous.firstCapturedAt ?? previous.capturedAt
                previous.text = s.text
                previous.contentHash = s.contentHash
                previous.url = s.url
                previous.filePath = s.filePath
                previous.capturedAt = s.capturedAt
                try previous.update(d)
                return previous
            }
            var copy = s
            try copy.insert(d)
            if let sample {
                // Statistics never cost a snapshot: a failure rolls back its savepoint only.
                do { try d.inSavepoint { try BoilerplateStore.record(sample, at: now, in: d); return .commit } } catch {
                    Logger(subsystem: "dev.remora", category: "boilerplate").error(
                        "sample record failed: \(String(describing: type(of: error)), privacy: .public)")
                }
            }
            return copy
        }
    }

    /// True when at least `continuationThreshold` of the old text's distinct non-empty lines
    /// (whitespace-collapsed) appear in the new text.
    static func continues(old: String, new: String) -> Bool {
        let oldLines = normalizedLines(old)
        guard !oldLines.isEmpty else { return false }
        let newLines = normalizedLines(new)
        let kept = oldLines.filter(newLines.contains).count
        return Double(kept) >= continuationThreshold * Double(oldLines.count)
    }

    private static func normalizedLines(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: \.isNewline).compactMap { line in
            let collapsed = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return collapsed.isEmpty ? nil : collapsed
        })
    }

    public func latestHash(app: String, windowTitle: String?) throws -> String? {
        try db.reader.read { d in
            try String.fetchOne(d, sql: """
                SELECT content_hash FROM snapshots
                WHERE app = ? AND window_title IS ?
                ORDER BY captured_at DESC, id DESC LIMIT 1
                """, arguments: [app, windowTitle])
        }
    }

    /// Served by the v2 covering index (no scan, no temp B-tree); runs on every tick.
    static let latestHashSQL = """
        SELECT content_hash FROM snapshots
        WHERE app = ? AND window_title IS ? AND source = ?
        ORDER BY captured_at DESC, id DESC LIMIT 1
        """

    /// Latest hash among snapshots of one source, so clipboard and window captures never dedupe each other.
    public func latestHash(app: String, windowTitle: String?, source: SnapshotSource) throws -> String? {
        try db.reader.read { d in
            try String.fetchOne(d, sql: Self.latestHashSQL,
                                arguments: [app, windowTitle, source.rawValue])
        }
    }

    public func search(_ query: String, app: String? = nil, since: Date? = nil,
                       until: Date? = nil, limit: Int = 10) throws -> [SnapshotHit] {
        guard let match = FTSQuery.make(from: query) else { return [] }
        var sql = """
            SELECT s.id, s.captured_at, s.app, s.window_title, s.domain,
                   snippet(snapshots_fts, 0, '[', ']', '…', 12) AS snippet
            FROM snapshots_fts JOIN snapshots s ON s.id = snapshots_fts.rowid
            WHERE snapshots_fts MATCH ?
            """
        var args: [(any DatabaseValueConvertible)?] = [match]
        if let app { sql += " AND s.app = ? COLLATE NOCASE"; args.append(app) }
        if let since { sql += " AND s.captured_at >= ?"; args.append(since) }
        if let until { sql += " AND s.captured_at <= ?"; args.append(until) }
        sql += " ORDER BY rank LIMIT ?"
        args.append(limit)
        let arguments = StatementArguments(args)
        return try db.reader.read { d in
            try Row.fetchAll(d, sql: sql, arguments: arguments).map(Self.hit)
        }
    }

    /// OR search over `terms`, best rank first. Rows matching BOTH `excludingApp` and
    /// `excludingTitle` (the window being written in) are left out; with no `excludingApp`
    /// nothing is excluded.
    public func searchAny(terms: [String], since: Date? = nil, excludingApp: String? = nil,
                          excludingTitle: String? = nil, limit: Int = 6) throws -> [SnapshotHit] {
        guard let match = FTSQuery.makeAny(terms: terms) else { return [] }
        var sql = """
            SELECT s.id, s.captured_at, s.app, s.window_title, s.domain,
                   snippet(snapshots_fts, 0, '[', ']', '…', 12) AS snippet
            FROM snapshots_fts JOIN snapshots s ON s.id = snapshots_fts.rowid
            WHERE snapshots_fts MATCH ?
            """
        var args: [(any DatabaseValueConvertible)?] = [match]
        if let since { sql += " AND s.captured_at >= ?"; args.append(since) }
        if let excludingApp {
            sql += " AND NOT (s.app = ? COLLATE NOCASE AND s.window_title IS ?)"
            args.append(excludingApp); args.append(excludingTitle)
        }
        sql += " ORDER BY rank LIMIT ?"
        args.append(limit)
        let arguments = StatementArguments(args)
        return try db.reader.read { d in
            try Row.fetchAll(d, sql: sql, arguments: arguments).map(Self.hit)
        }
    }

    public func snapshots(ids: [Int64]) throws -> [Snapshot] {
        try db.reader.read { d in
            try Snapshot.filter(keys: ids).order(Column("captured_at"), Column("id")).fetchAll(d)
        }
    }

    /// App names match case-insensitively (ASCII `NOCASE`).
    public func session(app: String, from: Date, to: Date, limit: Int) throws -> [Snapshot] {
        try db.reader.read { d in
            try Snapshot.fetchAll(d, sql: """
                SELECT * FROM snapshots
                WHERE app = ? COLLATE NOCASE AND captured_at >= ? AND captured_at <= ?
                ORDER BY captured_at, id LIMIT ?
                """, arguments: [app, from, to, limit])
        }
    }

    public func recent(limit: Int) throws -> [SnapshotHit] {
        try db.reader.read { d in
            try Row.fetchAll(d, sql: """
                SELECT id, captured_at, app, window_title, domain, substr(text, 1, 200) AS snippet
                FROM snapshots ORDER BY captured_at DESC, id DESC LIMIT ?
                """, arguments: [limit]).map(Self.hit)
        }
    }

    /// "Forget this" (user-initiated): deletes the snapshots (and their FTS rows) and runs
    /// `Provenance.cascade` over everything derived from them, in one transaction.
    /// `deleted["snapshots"]` is how many rows existed. Retention does not use this (F-61).
    @discardableResult
    public func delete(ids: [Int64], now: Date = Date()) throws -> ProvenanceReport {
        guard !ids.isEmpty else { return ProvenanceReport() }
        return try db.writer.write { d in try Self.delete(ids: ids, now: now, in: d) }
    }

    /// `delete(ids:now:)` inside an existing write (e.g. `DataGeneration.write`, which checks
    /// without bumping: a forget must not strand running jobs). Sets the forget marks
    /// (`ForgetMarks`) in the same write, so the stale digest and earlier chat stop reaching the
    /// cloud the moment the forget commits.
    @discardableResult
    public static func delete(ids: [Int64], now: Date = Date(), in d: Database) throws -> ProvenanceReport {
        let unique = Array(Set(ids)).sorted()
        guard !unique.isEmpty else { return ProvenanceReport() }
        var removed = 0
        for start in stride(from: 0, to: unique.count, by: Provenance.chunk) {
            let part = Array(unique[start..<min(start + Provenance.chunk, unique.count)])
            let marks = Array(repeating: "?", count: part.count).joined(separator: ",")
            try d.execute(sql: "DELETE FROM snapshots WHERE id IN (\(marks))", arguments: StatementArguments(part))
            removed += d.changesCount
        }
        var report = try Provenance.cascade(deletedSnapshotIDs: Set(unique), now: now, in: d)
        report.deleted["snapshots"] = removed
        try ForgetMarks.mark(now: now, in: d)
        return report
    }

    public func deleteAll() throws {
        try db.writer.write { d in _ = try Snapshot.deleteAll(d) }
    }

    private static func hit(_ r: Row) -> SnapshotHit {
        SnapshotHit(id: r["id"], capturedAt: r["captured_at"], app: r["app"],
                    windowTitle: r["window_title"], domain: r["domain"], snippet: r["snippet"])
    }
}
