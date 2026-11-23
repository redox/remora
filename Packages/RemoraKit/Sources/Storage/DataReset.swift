import GRDB

public enum DataReset {
    /// The captured data WAS deleted (the delete transaction committed), but the on-disk
    /// scrub (VACUUM + WAL truncate) failed twice. It is retried at the next launch
    /// (`scrubIfPending`). Callers must not report "nothing was removed".
    public struct CleanupPending: Error, Equatable {}

    static let scrubPendingKey = "scrubPending"

    /// Deletes every snapshot (and its FTS rows), activity event, inline output, style note,
    /// all derived memory (chronicles, wiki, flags, identity, ledger, jobs, embeddings,
    /// boilerplate, digest, snapshot tombstones, non-user time rules) and the assistant's chat
    /// turns, summaries, inbox, nudge decisions, reminders, imported meetings and saved notes in one transaction that also bumps
    /// `DataGeneration`, then scrubs what SQLite would otherwise leave recoverable on disk:
    /// - `secure_delete` overwrites freed content with zeros during the delete;
    /// - FTS `'delete-all'` drops every index segment (token text) at once;
    /// - `VACUUM` rebuilds the file without free pages;
    /// - `wal_checkpoint(TRUNCATE)` copies everything into the main file and truncates the WAL
    ///   to zero bytes (best effort: a concurrent reader, e.g. the MCP server mid-query, can
    ///   keep older frames alive until the next checkpoint).
    /// A `scrubPending` flag is set in the delete transaction and cleared once a scrub
    /// succeeds. If the scrub fails (after one immediate retry), throws `CleanupPending`; any
    /// other error means the delete rolled back and nothing was removed.
    /// Exclusions, user time rules, settings (except `derivedMemorySettings`) and `llm_calls` are
    /// kept. Slow on a large database: call off the main actor with capture held off (the app's
    /// barrier pause).
    public static func deleteAllCapturedData(in db: AppDatabase) throws {
        try deleteAllCapturedData(in: db, scrub: scrub)
    }

    static func deleteAllCapturedData(in db: AppDatabase, scrub: (Database) throws -> Void) throws {
        try db.writer.writeWithoutTransaction { d in
            let previous = try Int.fetchOne(d, sql: "PRAGMA secure_delete") ?? 0
            try d.execute(sql: "PRAGMA secure_delete = ON")
            defer { try? d.execute(sql: "PRAGMA secure_delete = \(previous == 0 ? 0 : 1)") }
            try d.inTransaction {
                _ = try Snapshot.deleteAll(d)
                try d.execute(sql: "INSERT INTO snapshots_fts(snapshots_fts) VALUES('delete-all')")
                _ = try ActivityEvent.deleteAll(d)
                _ = try SavedNote.deleteAll(d)
                try d.execute(sql: "INSERT INTO saved_notes_fts(saved_notes_fts) VALUES('delete-all')")
                try SettingsStore(db).setValue(nil as Bool?, forKey: SavedNoteStore.chatKey, in: d)
                _ = try ImportedMeeting.deleteAll(d)
                try d.execute(sql: "INSERT INTO imported_meetings_fts(imported_meetings_fts) VALUES('delete-all')")
                try d.execute(sql: "DELETE FROM forgotten_imports")
                try d.execute(sql: "DELETE FROM settings WHERE key IN (?, ?, ?)", arguments: [
                    ImportedMeetingStore.sourcesKey, ImportedMeetingStore.chatKey, ImportedMeetingStore.syncDatesKey,
                ])
                // Inline outputs and style notes hold user text; llm_calls holds none and stays.
                try d.execute(sql: "DELETE FROM inline_outputs")
                try d.execute(sql: "DELETE FROM style_notes")
                try deleteDerivedMemory(d)
                try d.execute(sql: "INSERT OR REPLACE INTO settings (key, value) VALUES (?, '1')",
                              arguments: [scrubPendingKey])
                return .commit
            }
            // Committed: from here on, failures are "deleted, cleanup pending".
            for attempt in 1...2 {
                do {
                    try scrubAndClear(d, scrub)
                    return
                } catch where attempt == 1 {
                    continue
                } catch {
                    throw CleanupPending()
                }
            }
        }
    }

    /// Every table derived from captured data (plan 4 memory). `wiki_facts` goes before
    /// `wiki_pages` (it references them).
    static let derivedMemoryTables = [
        "working_memory", "chronicle", "wiki_facts", "wiki_pages", "identity", "salient_flags", "time_ledger",
        "jobs", "embeddings", "boilerplate", "boilerplate_stats", "boilerplate_surfaces", "memory_digest",
        "snapshot_sources",
    ]

    /// Plan 5 tables: chat, inbox, nudge decisions and reminders hold user and model text. Child
    /// tables first (turns cite inbox rows; inbox rows cite reminders).
    static let assistantTables = ["chat_turns", "chat_summaries", "inbox_messages", "nudge_decisions", "reminders"]

    /// Memory settings that point into deleted data (watermarks, last runs, backoff). The user's
    /// choices (`memory.enabled/language/retention`) are kept.
    static let derivedMemorySettings = [
        "memory.plannerWatermark", "memory.wm.lastSnapshotAt", "memory.compaction.last", "memory.backoff",
        "memory.lastStyleRunAt", "memory.style.consumed", "memory.plannerWatermarkHeld",
        ForgetMarks.digestDirtyKey, ForgetMarks.chatForgetAtKey, RoutineFeedback.settingsKey, RoutineFindings.seenKey,
        // Reminder ids and dates only, but the reminders are gone (Plan 5).
        "reminders.pendingPrompts",
    ]

    /// Inside the delete-all transaction: empties derived memory, its FTS indexes and the assistant
    /// tables, keeps the user's own time rules, and bumps `DataGeneration` so an in-flight job's
    /// result is refused.
    private static func deleteDerivedMemory(_ d: Database) throws {
        for table in assistantTables + derivedMemoryTables { try d.execute(sql: "DELETE FROM \(table)") }
        try d.execute(sql: "DELETE FROM time_rules WHERE source <> ?", arguments: [TimeRule.userSource])
        for fts in ["chronicle_fts", "wiki_pages_fts", "wiki_facts_fts"] {
            try d.execute(sql: "INSERT INTO \(fts)(\(fts)) VALUES('delete-all')")
        }
        for key in derivedMemorySettings {
            try d.execute(sql: "DELETE FROM settings WHERE key = ?", arguments: [key])
        }
        try DataGeneration.bump(in: d)
    }

    public static func isScrubPending(in db: AppDatabase) throws -> Bool {
        try db.reader.read { d in
            try Bool.fetchOne(d, sql: "SELECT 1 FROM settings WHERE key = ?", arguments: [scrubPendingKey]) ?? false
        }
    }

    /// Runs a scrub left pending by a delete-all whose cleanup failed. Call at launch, off
    /// the main actor. Returns true if a pending scrub ran (and the flag was cleared).
    @discardableResult
    public static func scrubIfPending(in db: AppDatabase) throws -> Bool {
        try scrubIfPending(in: db, scrub: scrub)
    }

    @discardableResult
    static func scrubIfPending(in db: AppDatabase, scrub: (Database) throws -> Void) throws -> Bool {
        guard try isScrubPending(in: db) else { return false }
        try db.writer.writeWithoutTransaction { d in
            let previous = try Int.fetchOne(d, sql: "PRAGMA secure_delete") ?? 0
            try d.execute(sql: "PRAGMA secure_delete = ON")
            defer { try? d.execute(sql: "PRAGMA secure_delete = \(previous == 0 ? 0 : 1)") }
            try scrubAndClear(d, scrub)
        }
        return true
    }

    /// Clears the flag first (so the scrub also rewrites that page), then scrubs. If the scrub
    /// throws, the flag is restored.
    private static func scrubAndClear(_ d: Database, _ scrub: (Database) throws -> Void) throws {
        try d.execute(sql: "DELETE FROM settings WHERE key = ?", arguments: [scrubPendingKey])
        do { try scrub(d) } catch {
            try? d.execute(sql: "INSERT OR REPLACE INTO settings (key, value) VALUES (?, '1')",
                           arguments: [scrubPendingKey])
            throw error
        }
    }

    static func scrub(_ d: Database) throws {
        try d.execute(sql: "VACUUM")
        try d.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
    }
}
