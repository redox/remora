import Foundation
import GRDB

enum Migrations {
    static func make() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "snapshots") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("captured_at", .datetime).notNull().indexed()
                t.column("app", .text).notNull().indexed()
                t.column("bundle_id", .text)
                t.column("window_title", .text)
                t.column("url", .text)
                t.column("domain", .text).indexed()
                t.column("file_path", .text)
                t.column("text", .text).notNull()
                t.column("content_hash", .text).notNull()
                t.column("source", .text).notNull()
            }
            try db.create(virtualTable: "snapshots_fts", using: FTS5()) { t in
                t.synchronize(withTable: "snapshots")
                t.tokenizer = .unicode61(diacritics: .remove)
                t.prefixes = [2, 3]
                t.column("text")
                t.column("window_title")
            }
            try db.create(table: "activity_events") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("app", .text).notNull()
                t.column("bundle_id", .text)
                t.column("window_title", .text)
                t.column("domain", .text)
                t.column("started_at", .datetime).notNull().indexed()
                t.column("ended_at", .datetime).notNull()
            }
            try db.create(table: "exclusions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("pattern", .text).notNull().unique()
                t.column("created_at", .datetime).notNull()
            }
            try db.create(table: "settings") { t in
                t.primaryKey("key", .text)
                t.column("value", .text)
            }
        }
        // v2 (final review): per-tick lookups must not scan. Never edit v1: real databases
        // already hold v1 data.
        migrator.registerMigration("v2") { db in
            // Covering index for the dedupe lookup (latest hash per app/window/source) and the
            // rolling-snapshot candidate lookup. `id` (the rowid) is listed before
            // `content_hash` so `ORDER BY captured_at DESC, id DESC` is served by the index
            // with no temp B-tree.
            try db.create(index: "snapshots_on_app_title_source_time_hash", on: "snapshots",
                          columns: ["app", "window_title", "source", "captured_at", "id", "content_hash"])
            try db.create(index: "activity_events_on_ended_at", on: "activity_events",
                          columns: ["ended_at"])
            // Creation time of a row that rolling snapshots keep updating (`captured_at` moves
            // to the latest update); bounds how long one row may keep rolling.
            try db.alter(table: "snapshots") { t in t.add(column: "first_captured_at", .datetime) }
            try db.execute(sql: "UPDATE snapshots SET first_captured_at = captured_at")
        }
        // v3 (plan 2): LLM accounting, inline outputs, per-surface style notes. Never edit v1/v2.
        migrator.registerMigration("v3") { db in
            try db.create(table: "llm_calls") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("started_at", .datetime).notNull().indexed()
                t.column("duration_ms", .integer).notNull()
                t.column("backend", .text).notNull()
                t.column("model", .text).notNull()
                t.column("reasoning_effort", .text)
                t.column("job_type", .text).notNull()
                t.column("status", .text).notNull()
                t.column("error_code", .text)
                t.column("input_tokens", .integer).notNull().defaults(to: 0)
                t.column("cached_input_tokens", .integer).notNull().defaults(to: 0)
                t.column("output_tokens", .integer).notNull().defaults(to: 0)
                t.column("reasoning_tokens", .integer).notNull().defaults(to: 0)
                t.column("est_cost_usd", .double)
                t.column("artifact_table", .text)
                t.column("artifact_id", .integer)
            }
            try db.create(index: "llm_calls_on_job_type_started_at", on: "llm_calls",
                          columns: ["job_type", "started_at"])
            try db.create(table: "inline_outputs") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("created_at", .datetime).notNull().indexed()
                t.column("llm_call_id", .integer).references("llm_calls", onDelete: .setNull)
                t.column("mode", .text).notNull()
                t.column("app", .text).notNull()
                t.column("bundle_id", .text)
                t.column("surface", .text).notNull()
                t.column("original", .text).notNull()
                t.column("instruction", .text)
                t.column("result", .text).notNull()
                t.column("outcome", .text)
                t.column("final_text", .text)
                t.column("checked_at", .datetime)
            }
            try db.create(table: "style_notes") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("surface", .text).notNull().unique()
                t.column("notes", .text).notNull()
                t.column("updated_at", .datetime).notNull()
                t.column("llm_call_id", .integer).references("llm_calls", onDelete: .setNull)
            }
        }
        // v4 (plan 4): background memory. Never edit v1–v3.
        migrator.registerMigration("v4", migrate: migrateV4)
        // v4.1: databases that ran v4 before it gained `snapshot_sources` and
        // `boilerplate_stats.last_seen_at` (build fa8eb12). A no-op on a database v4 created now.
        migrator.registerMigration("v4.1", migrate: migrateV4_1)
        // v5 (plan 5): chat, inbox, reminders, nudge decisions. Never edit v1–v4.1.
        migrator.registerMigration("v5", migrate: migrateV5)
        migrator.registerMigration("v6") { db in
            try db.create(table: "imported_meetings") { t in
                t.column("source_id", .blob).notNull()
                t.column("remote_id", .text).notNull()
                t.column("started_at", .datetime).notNull().indexed()
                t.column("title", .text).notNull()
                t.column("body", .text).notNull()
                t.primaryKey(["source_id", "remote_id"])
            }
            try db.create(virtualTable: "imported_meetings_fts", using: FTS5()) { t in
                t.synchronize(withTable: "imported_meetings")
                t.tokenizer = .unicode61(diacritics: .remove)
                t.prefixes = [2, 3]
                t.column("title")
                t.column("body")
            }
            try db.create(table: "forgotten_imports") { t in
                t.primaryKey("digest", .blob)
            }
        }
        migrator.registerMigration("v7") { db in
            try db.alter(table: "exclusions") { t in
                t.add(column: "manual_saves", .boolean).notNull().defaults(to: false)
            }
            try db.alter(table: "chat_turns") { t in
                t.add(column: "used_saved_notes", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "saved_notes") { t in
                t.primaryKey("id", .blob)
                t.column("text", .text).notNull()
                t.column("annotation", .text).notNull()
                t.column("created_at", .datetime).notNull().indexed()
            }
            try db.create(virtualTable: "saved_notes_fts", using: FTS5()) { t in
                t.synchronize(withTable: "saved_notes")
                t.tokenizer = .unicode61(diacritics: .remove)
                t.prefixes = [2, 3]
                t.column("text")
                t.column("annotation")
            }
        }
        return migrator
    }

    /// Idempotent: creates `snapshot_sources` and adds `boilerplate_stats.last_seen_at` only when
    /// missing. SQLite needs a constant default to add a NOT NULL column, so the column gets
    /// `'1970-01-01 00:00:00.000'` and the rows already there are stamped now (their stats would
    /// otherwise be pruned at the next compaction). `BoilerplateStore.record` always writes it.
    private static func migrateV4_1(_ db: Database) throws {
        if try !db.tableExists("snapshot_sources") {
            try db.create(table: "snapshot_sources") { t in
                t.primaryKey("id", .integer)
                t.column("app", .text)
                t.column("bundle_id", .text)
                t.column("domain", .text)
                t.column("url_host", .text)
            }
        }
        if try !db.columns(in: "boilerplate_stats").contains(where: { $0.name == "last_seen_at" }) {
            try db.execute(sql: """
                ALTER TABLE boilerplate_stats ADD COLUMN last_seen_at DATETIME NOT NULL DEFAULT '1970-01-01 00:00:00.000'
                """)
            try db.execute(sql: "UPDATE boilerplate_stats SET last_seen_at = ?", arguments: [Date()])
        }
    }

    /// FTS5 over a v4 table, kept in sync by triggers, with v1's tokenizer (accent-insensitive
    /// for French, prefix indexes 2 and 3).
    private static func createSynchronizedFTS(_ db: Database, _ name: String, on table: String,
                                              columns: [String]) throws {
        try db.create(virtualTable: name, using: FTS5()) { t in
            t.synchronize(withTable: table)
            t.tokenizer = .unicode61(diacritics: .remove)
            t.prefixes = [2, 3]
            for c in columns { t.column(c) }
        }
    }

    private static func migrateV4(_ db: Database) throws {
        // CHECK lists are literal SQL, not derived from the Swift enums: a migration is frozen.
        func llmCallID(_ t: TableDefinition) {
            t.column("llm_call_id", .integer).references("llm_calls", onDelete: .setNull)
        }

        try db.create(table: "jobs") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("kind", .text).notNull()
            t.column("period_key", .text).notNull()
            t.column("period_start", .datetime)
            t.column("period_end", .datetime)
            t.column("status", .text).notNull().defaults(to: "pending")
                .check(sql: "status IN ('pending','running','done','skipped','failed')")
            t.column("priority", .integer).notNull()
            t.column("attempts", .integer).notNull().defaults(to: 0)
            t.column("next_run_at", .datetime).notNull()
            t.column("last_error", .text)
            t.column("created_at", .datetime).notNull()
            t.column("updated_at", .datetime).notNull()
            t.uniqueKey(["kind", "period_key"])
        }
        try db.create(index: "jobs_on_status_next_run_at_priority", on: "jobs",
                      columns: ["status", "next_run_at", "priority"])

        try db.create(table: "working_memory") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("text", .text).notNull()
            t.column("kind", .text).notNull()
            t.column("norm_key", .text).notNull().unique()
            t.column("relevance", .double).notNull()
            t.column("snapshot_ids", .text).notNull().defaults(to: "[]")
            t.column("added_at", .datetime).notNull()
            t.column("last_seen_at", .datetime).notNull()
            llmCallID(t)
        }

        try db.create(table: "chronicle") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("level", .text).notNull().check(sql: "level IN ('hour','day','week','month','year')")
            t.column("period_key", .text).notNull()
            t.column("period_start", .datetime).notNull()
            t.column("period_end", .datetime).notNull()
            t.column("summary", .text).notNull()
            t.column("metadata", .text).notNull().defaults(to: "{}")
            t.column("snapshot_ids", .text).notNull().defaults(to: "[]")
            t.column("child_ids", .text).notNull().defaults(to: "[]")
            t.column("is_dirty", .integer).notNull().defaults(to: 0)
            t.column("generated_at", .datetime).notNull()
            llmCallID(t)
            t.uniqueKey(["level", "period_key"])
        }
        try db.create(index: "chronicle_on_level_period_start", on: "chronicle", columns: ["level", "period_start"])
        try createSynchronizedFTS(db, "chronicle_fts", on: "chronicle", columns: ["summary", "period_key"])

        try db.create(table: "wiki_pages") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("slug", .text).notNull().unique()
            t.column("type", .text).notNull().check(sql: "type IN ('person','project','topic','tool','org')")
            t.column("title", .text).notNull()
            t.column("aliases", .text).notNull().defaults(to: "[]")
            t.column("summary", .text).notNull().defaults(to: "")
            t.column("body", .text).notNull().defaults(to: "")
            t.column("links", .text).notNull().defaults(to: "[]")
            t.column("mention_count", .integer).notNull().defaults(to: 0)
            t.column("first_seen", .datetime).notNull()
            t.column("last_seen", .datetime).notNull()
            t.column("is_dirty", .integer).notNull().defaults(to: 0)
            t.column("snapshot_ids", .text).notNull().defaults(to: "[]")
            t.column("updated_at", .datetime).notNull()
            llmCallID(t)
        }
        try db.create(index: "wiki_pages_on_type", on: "wiki_pages", columns: ["type"])
        try db.create(index: "wiki_pages_on_is_dirty", on: "wiki_pages", columns: ["is_dirty"])
        try db.create(index: "wiki_pages_on_last_seen", on: "wiki_pages", columns: ["last_seen"])
        try createSynchronizedFTS(db, "wiki_pages_fts", on: "wiki_pages",
                                  columns: ["title", "aliases", "summary", "body"])

        try db.create(table: "wiki_facts") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("slug", .text).notNull()
                .references("wiki_pages", column: "slug", onDelete: .cascade, onUpdate: .cascade)
            t.column("fact", .text).notNull()
            t.column("norm_key", .text).notNull()
            t.column("subject", .text).notNull().check(sql: "subject IN ('user','world','third_party')")
            t.column("basis", .text).notNull()
                .check(sql: "basis IN ('observed_action','on_screen_content','user_stated','inferred')")
            t.column("worth", .text).notNull().check(sql: "worth IN ('core','detail')")
            t.column("snapshot_ids", .text).notNull().defaults(to: "[]")
            t.column("valid_at", .datetime).notNull()
            t.column("invalid_at", .datetime)
            t.column("superseded_by", .integer).references("wiki_facts", onDelete: .setNull)
            t.column("recorded_at", .datetime).notNull()
            t.column("last_confirmed_at", .datetime).notNull()
            llmCallID(t)
            t.uniqueKey(["slug", "norm_key"])
        }
        try db.create(index: "wiki_facts_on_slug_invalid_at", on: "wiki_facts", columns: ["slug", "invalid_at"])
        try db.create(index: "wiki_facts_on_superseded_by", on: "wiki_facts", columns: ["superseded_by"])
        try createSynchronizedFTS(db, "wiki_facts_fts", on: "wiki_facts", columns: ["fact"])

        try db.create(table: "identity") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("body", .text).notNull()
            t.column("source", .text).notNull().check(sql: "source IN ('llm','user')")
            t.column("created_at", .datetime).notNull()
            llmCallID(t)
        }

        try db.create(table: "salient_flags") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("kind", .text).notNull().check(sql: "kind IN ('event','email','commitment','todo')")
            t.column("text", .text).notNull()
            t.column("owner", .text).notNull().check(sql: "owner IN ('user','other')")
            t.column("person", .text).notNull().defaults(to: "")
            t.column("project", .text).notNull().defaults(to: "")
            t.column("due_at", .datetime)
            t.column("status", .text).notNull().defaults(to: "open")
                .check(sql: "status IN ('open','done','dismissed','expired')")
            t.column("confidence", .double).notNull().defaults(to: 0.5)
            t.column("quote", .text).notNull().defaults(to: "")
            t.column("snapshot_ids", .text).notNull().defaults(to: "[]")
            t.column("close_snapshot_ids", .text).notNull().defaults(to: "[]")
            t.column("period_key", .text)
            t.column("dedupe_key", .text).notNull().unique()
            t.column("created_at", .datetime).notNull()
            t.column("last_seen_at", .datetime).notNull()
            t.column("closed_at", .datetime)
            t.column("checked_at", .datetime)
            llmCallID(t)
        }
        try db.create(index: "salient_flags_on_status_kind", on: "salient_flags", columns: ["status", "kind"])
        try db.create(index: "salient_flags_on_due_at", on: "salient_flags", columns: ["due_at"])

        // `project`/`app` are NOT NULL ('' = none): SQLite lets NULLs repeat in a primary key.
        try db.create(table: "time_ledger") { t in
            t.column("hour_start", .datetime).notNull()
            t.column("project", .text).notNull().defaults(to: "")
            t.column("app", .text).notNull().defaults(to: "")
            t.column("domain", .text).notNull().defaults(to: "")
            t.column("seconds", .double).notNull()
            t.primaryKey(["hour_start", "project", "app", "domain"])
        }
        try db.create(table: "time_rules") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("project", .text).notNull()
            t.column("app", .text)
            t.column("domain", .text)
            t.column("title_contains", .text)
            t.column("source", .text).notNull().defaults(to: "user")
            t.column("created_at", .datetime).notNull()
        }

        try db.create(table: "embeddings") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("owner_table", .text).notNull()
            t.column("owner_id", .integer).notNull()
            t.column("model_id", .text).notNull()
            t.column("revision", .integer).notNull()
            t.column("dims", .integer).notNull()
            t.column("vector", .blob).notNull()
            t.column("content_hash", .text).notNull()
            t.column("created_at", .datetime).notNull()
            t.uniqueKey(["owner_table", "owner_id"])
        }
        try db.create(index: "embeddings_on_model_id_revision", on: "embeddings", columns: ["model_id", "revision"])

        try db.create(table: "boilerplate") { t in
            t.column("surface", .text).notNull()
            t.column("line_hash", .text).notNull()
            t.column("line_text", .text).notNull()
            t.column("learned_at", .datetime).notNull()
            t.primaryKey(["surface", "line_hash"])
        }
        try db.create(table: "boilerplate_stats") { t in
            t.column("surface", .text).notNull()
            t.column("line_hash", .text).notNull()
            t.column("line_text", .text).notNull()
            t.column("docs", .double).notNull()
            // When a captured document last showed the line: compaction prunes stats older than
            // the retention window.
            t.column("last_seen_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            t.primaryKey(["surface", "line_hash"])
        }
        try db.create(table: "boilerplate_surfaces") { t in
            t.primaryKey("surface", .text)
            t.column("docs", .double).notNull()
            t.column("fitted_at", .datetime)
        }

        // Tombstones: where a snapshot deleted by retention came from (no text), so derived rows
        // citing it are still judged under the exclusions as they stand now (`DerivedPolicy`).
        try db.create(table: "snapshot_sources") { t in
            t.primaryKey("id", .integer)
            t.column("app", .text)
            t.column("bundle_id", .text)
            t.column("domain", .text)
            t.column("url_host", .text)
        }

        try db.create(table: "memory_digest") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("body", .text).notNull()
            t.column("created_at", .datetime).notNull()
            llmCallID(t)
        }
    }

    private static func migrateV5(_ db: Database) throws {
        // CHECK lists are literal SQL, not derived from the Swift enums: a migration is frozen.
        try db.create(table: "reminders") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("text", .text).notNull()
            t.column("action", .text).notNull().check(sql: "action IN ('notify','prompt')")
            t.column("kind", .text).notNull().check(sql: "kind IN ('once','recurring','interval')")
            t.column("anchor_at", .datetime).notNull()
            t.column("rrule", .text)
            t.column("interval_seconds", .integer)
            t.column("time_zone", .text).notNull()
            t.column("next_fire_at", .datetime)
            t.column("fire_count", .integer).notNull().defaults(to: 0)
            t.column("last_fired_at", .datetime)
            t.column("status", .text).notNull().defaults(to: "active")
                .check(sql: "status IN ('active','done','cancelled')")
            t.column("created_by", .text).notNull().check(sql: "created_by IN ('user','chat')")
            t.column("created_at", .datetime).notNull()
        }
        try db.create(index: "reminders_on_status_next_fire_at", on: "reminders", columns: ["status", "next_fire_at"])

        try db.create(table: "inbox_messages") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("kind", .text).notNull()
                .check(sql: "kind IN ('morning_brief','evening_wrap','nudge','reminder')")
            t.column("title", .text).notNull()
            t.column("body", .text).notNull()
            t.column("dedupe_key", .text).notNull().unique()
            t.column("created_at", .datetime).notNull()
            t.column("seen_at", .datetime)
            t.column("notified", .integer).notNull().defaults(to: 0)
            t.column("reminder_id", .integer).references("reminders", onDelete: .setNull)
            t.column("flag_id", .integer).references("salient_flags", onDelete: .setNull)
            t.column("llm_call_ids", .text).notNull().defaults(to: "[]")
        }
        try db.create(index: "inbox_messages_on_created_at", on: "inbox_messages", columns: ["created_at"])

        try db.create(table: "chat_turns") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("created_at", .datetime).notNull()
            t.column("role", .text).notNull().check(sql: "role IN ('user','assistant')")
            t.column("text", .text).notNull()
            t.column("status", .text).notNull().check(sql: "status IN ('pending','complete','cancelled','failed')")
            t.column("error", .text)
            t.column("tools", .text).notNull().defaults(to: "[]")
            t.column("llm_call_ids", .text).notNull().defaults(to: "[]")
            t.column("inbox_id", .integer).references("inbox_messages", onDelete: .setNull)
            t.column("folded", .integer).notNull().defaults(to: 0)
            t.column("tainted", .integer).notNull().defaults(to: 0)
        }
        try db.create(index: "chat_turns_on_created_at", on: "chat_turns", columns: ["created_at"])

        try db.create(table: "chat_summaries") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("through_turn_id", .integer).notNull()
            t.column("body", .text).notNull()
            t.column("created_at", .datetime).notNull()
            t.column("llm_call_id", .integer).references("llm_calls", onDelete: .setNull)
        }

        try db.create(table: "nudge_decisions") { t in
            t.primaryKey("flag_id", .integer).references("salient_flags", onDelete: .cascade)
            t.column("decision", .text).notNull().check(sql: "decision IN ('sent','declined','unverified')")
            t.column("flag_last_seen_at", .datetime).notNull()
            t.column("decided_at", .datetime).notNull()
            t.column("llm_call_id", .integer).references("llm_calls", onDelete: .setNull)
        }
    }
}
