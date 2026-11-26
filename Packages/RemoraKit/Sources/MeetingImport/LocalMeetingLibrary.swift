import Capture
import Foundation
import GRDB
import LLM
import Redaction
import Storage

public struct LocalMeetingSummary: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let startedAt: Date
    public let client: String
    public let interrupted: Bool

    fileprivate init(_ row: Row) {
        id = row["id"]
        title = row["title"]
        startedAt = row["started_at"]
        client = row["client"]
        interrupted = row["interrupted"]
    }
}

public struct LocalMeetingDetail: Sendable {
    public let summary: LocalMeetingSummary
    public let transcript: String
    public let notes: String?
}

public struct RecordingExcerpt: Sendable {
    public let meeting: LocalMeetingSummary
    public let transcript: String
    public let notes: String?
}

/// Remora recordings have their own index. Imported-meeting chat access never grants access to it.
public actor LocalMeetingLibrary {
    private let db: AppDatabase
    private let redactor = Redactor()
    private let now: @Sendable () -> Date

    public init(db: AppDatabase, now: @escaping @Sendable () -> Date = Date.init) {
        self.db = db
        self.now = now
    }

    /// The transcript commits independently of any later attempt to generate notes.
    public func save(client: String, title: String, startedAt: Date, transcript: String,
                     interrupted: Bool, context: WindowContext, generation: Int) throws -> UUID {
        guard let bundle = context.bundleID, !bundle.isEmpty, !context.app.isEmpty,
              !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MeetingImportError.invalidResponse
        }
        let id = UUID()
        let arguments: StatementArguments = [
            id, startedAt, redactor.redact(client), redactor.redact(title), redactor.redact(transcript), interrupted,
            redactor.redact(context.app), redactor.redact(bundle), context.windowTitle.map(redactor.redact),
            context.url.map { redactor.redact($0.absoluteString) }, context.filePath.map(redactor.redact),
        ]
        try DataGeneration.write(db, expected: generation) { d in
            try checkRecordingAllowed(context, in: d)
            try d.execute(sql: """
                INSERT INTO local_meetings(id, started_at, client, title, transcript, interrupted,
                                           source_app, source_bundle, source_title, source_url, source_path)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: arguments)
        }
        return id
    }

    public func search(_ query: String) throws -> [LocalMeetingSummary] {
        try db.reader.read { d in
            try Self.searchRows(query, limit: 100, excerpts: false, in: d, map: LocalMeetingSummary.init)
        }
    }

    /// Search authorization, source exclusions and excerpts all come from one read snapshot.
    public func excerpts(_ query: String, for access: RecordingSearchAccess) throws -> [RecordingExcerpt]? {
        try db.reader.read { d in
            guard try access.allows(in: d, now: now()) else { return nil }
            guard query.utf8.count <= 256 else { return [] }
            return try Self.searchRows(query, limit: 5, excerpts: true, in: d) { row in
                let transcript: String = row["transcript"]
                let notes: String? = row["notes"]
                return RecordingExcerpt(meeting: LocalMeetingSummary(row),
                                        transcript: Self.excerpt(transcript, passage: row["passage"], limit: 1800),
                                        notes: notes.map { Self.excerpt($0, passage: row["note_passage"], limit: 800) })
            }
        }
    }

    /// FTS can start a passage mid-utterance. Include the preceding timestamp and speaker when nearby.
    private static func excerpt(_ text: String, passage: String?, limit: Int) -> String {
        guard let passage, !passage.isEmpty, let range = text.range(of: passage) else {
            return String(text.prefix(limit))
        }
        let lower = text.index(range.lowerBound, offsetBy: -300, limitedBy: text.startIndex) ?? text.startIndex
        let prefix = text[lower..<range.lowerBound]
        let start = prefix.lastIndex(of: "\n").map { text.index(after: $0) } ?? lower
        return String(text[start...].prefix(limit))
    }

    /// Chat replies can inherit several recordings. Withhold a reply if any source is unavailable.
    public func allowedChatIDs(_ ids: Set<UUID>, since start: Date, at date: Date) throws -> Set<UUID> {
        guard !ids.isEmpty else { return [] }
        return try db.reader.read { d in
            guard try RecordingSearchAccess.chat.allows(in: d, now: date),
                  ForgetMarks.chatForgetAt(in: d).map({ $0 <= start }) ?? true else { return [] }
            let policy = try Self.policy(in: d)
            return try ids.filter { id in
                guard let row = try Row.fetchOne(d, sql: """
                    SELECT source_app, source_bundle, source_title, source_url, source_path
                    FROM local_meetings WHERE id = ?
                    """, arguments: [id]) else { return false }
                return Self.allows(row, policy: policy)
            }
        }
    }

    private static func searchRows<T>(_ query: String, limit: Int, excerpts: Bool, in d: Database,
                                      map: (Row) -> T) throws -> [T] {
        let columns = "m.id, m.started_at, m.title, m.client, m.interrupted, m.source_app, m.source_bundle, m.source_title, m.source_url, m.source_path"
        let sql: String
        var args = StatementArguments()
        if let match = FTSQuery.make(from: query) {
            // FTS5 finds the relevant passage even when the match occurs late in a long transcript.
            let passages = excerpts ? """
                , m.transcript, m.notes, snippet(local_meetings_fts, 2, '', '', '', 48) AS passage,
                  snippet(local_meetings_fts, 3, '', '', '', 32) AS note_passage
                """ : ""
            sql = """
                SELECT \(columns) \(passages) FROM local_meetings_fts JOIN local_meetings m ON m.rowid = local_meetings_fts.rowid
                WHERE local_meetings_fts MATCH ? ORDER BY rank, m.started_at DESC, m.rowid DESC
                """
            args = [match]
        } else {
            guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
            let passages = excerpts ? ", substr(m.transcript, 1, 1800) AS transcript, substr(m.notes, 1, 800) AS notes, NULL AS passage, NULL AS note_passage" : ""
            sql = "SELECT \(columns) \(passages) FROM local_meetings m ORDER BY m.started_at DESC, m.rowid DESC"
        }
        let policy = try Self.policy(in: d)
        let cursor = try Row.fetchCursor(d, sql: sql, arguments: args)
        var results: [T] = []
        while results.count < limit, let row = try cursor.next() {
            if Self.allows(row, policy: policy) { results.append(map(row)) }
        }
        return results
    }

    public func detail(id: UUID) throws -> LocalMeetingDetail? {
        try db.reader.read { d in
            guard let row = try Row.fetchOne(d, sql: "SELECT * FROM local_meetings WHERE id = ?", arguments: [id]),
                  try Self.allows(row, policy: Self.policy(in: d)) else { return nil }
            return LocalMeetingDetail(summary: LocalMeetingSummary(row), transcript: row["transcript"], notes: row["notes"])
        }
    }

    public func forget(id: UUID) throws {
        try db.writer.write { d in
            try d.execute(sql: "DELETE FROM local_meetings WHERE id = ?", arguments: [id])
            if d.changesCount > 0, (try? RecordingSearchAccess.chat.enabled(in: d)) != false {
                try ForgetMarks.markChat(now: now(), in: d)
            }
        }
    }

    public func generateNotes(id: UUID, context: WindowContext, generation: Int, llm: LLMService) async throws {
        guard let recording = try detail(id: id), recording.notes == nil else { return }
        let notes = try await MeetingNotes.generate(transcript: recording.transcript, llm: llm) {
            try await self.checkForNotes(id: id, context: context, generation: generation)
        }
        try updateNotes(redactor.redact(notes), id: id, context: context, generation: generation)
    }

    private func checkForNotes(id: UUID, context: WindowContext, generation: Int) throws {
        // Keep each model request tied to live evidence, even for a meeting spanning many chunks.
        try DataGeneration.write(db, expected: generation) { d in
            try checkRecordingAllowed(context, recording: id, in: d)
        }
    }

    private func updateNotes(_ notes: String, id: UUID, context: WindowContext, generation: Int) throws {
        try DataGeneration.write(db, expected: generation) { d in
            try checkRecordingAllowed(context, recording: id, in: d)
            // A forget between generation and completion wins. Updating can never recreate the row.
            try d.execute(sql: "UPDATE local_meetings SET notes = ? WHERE id = ? AND notes IS NULL", arguments: [notes, id])
        }
    }

    private func checkRecordingAllowed(_ context: WindowContext, recording id: UUID? = nil, in d: Database) throws {
        try Task.checkCancellation()
        if let until = try SettingsStore(db).pausedUntil(in: d), until > now() { throw MeetingImportError.paused }
        let policy = try Self.policy(in: d)
        guard policy.shouldCapture(context) else { throw MeetingImportError.excluded }
        if let id {
            let source = try Row.fetchOne(d, sql: """
                SELECT source_app, source_bundle, source_title, source_url, source_path FROM local_meetings WHERE id = ?
                """, arguments: [id])
            guard let source else { throw CancellationError() }
            guard Self.allows(source, policy: policy) else { throw MeetingImportError.excluded }
        }
    }

    private static func policy(in d: Database) throws -> CapturePolicy {
        let rules = try ExclusionStore.all(in: d).map { pattern in
            guard let rule = ExclusionRule(pattern: pattern) else { throw MeetingImportError.excluded }
            return rule
        }
        return CapturePolicy(userRules: rules)
    }

    private static func allows(_ row: Row, policy: CapturePolicy) -> Bool {
        let url: String? = row["source_url"]
        let context = WindowContext(app: row["source_app"], bundleID: row["source_bundle"],
                                    windowTitle: row["source_title"], url: url.flatMap(URL.init(string:)),
                                    filePath: row["source_path"])
        return policy.shouldCapture(context)
    }
}
