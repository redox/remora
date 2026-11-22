---
name: remora-database
description: Use before adding or changing a table, column, index, migration, setting key or store in Remora, or before writing to the database from a background job, the chat, MCP or a migration. Covers frozen GRDB migrations, write reentrancy, DataGeneration, SettingsStore, delete-all coverage and database tests.
---

# Remora database rules

Storage is one SQLite database (GRDB, WAL mode, foreign keys on) at
`~/Library/Application Support/Remora/remora.sqlite`, owned by the app. `remora-mcp` opens it
read-only (`AppDatabase.openReadOnly`). All of it lives in `Packages/RemoraKit/Sources/Storage`.

**Never open, edit, copy or delete the user's real database.** Tests use
`AppDatabase.inMemory()`.

## Migrations are frozen

- `Storage/Migrations.swift` registers `v1`, `v2`, `v3`, `v4`, `v4.1`, `v5`… Real databases have
  already run every released migration, so **never edit one that has shipped or been installed**.
  Add a new migration (`v6`, or a point release like `v4.1` for a repair).
- A repair migration must be **idempotent**: check `columns(in:)` / `tableExists` and do nothing
  on a database that is already right (see `migrateV4_1`).
- Inside a migration, write literal SQL for CHECK lists and defaults, never values derived from
  Swift enums: an enum can change later, but the migration must not.
- Adding a NOT NULL column needs a constant default; stamp existing rows explicitly if the default
  would be wrong for them.
- FTS5 tables use `unicode61(diacritics: .remove)` (French and English, accent-insensitive) with
  prefix indexes, kept in sync by triggers.
- Every migration gets a test in `StorageTests` that opens an in-memory database and checks the
  schema (and, for a repair, that it is a no-op on a fresh database).

## Writes are not reentrant

GRDB serialises writes: calling `db.writer.write` (or any store method that writes) **inside**
another write closure deadlocks or throws. So:

- Inside a write closure, use only the `in d: Database` overloads (`SettingsStore.value(_:forKey:in:)`,
  `setValue(_:forKey:in:)`, `SnapshotStore.delete(ids:now:in:)`, `ForgetMarks.mark(now:in:)`…).
  When you add a store method that a transaction needs, add its `in d:` overload too.
- Don't read through a store's own `reader.read` inside a read or write closure either.
- Load anything slow or policy-related (`SnapshotPolicy.current`) **before** opening the write.

## Background jobs and delete-all: `DataGeneration`

A job that reads data, calls a model (slow), then writes a result could resurrect data the user
deleted meanwhile. The pattern:

```swift
let generation = try DataGeneration.current(db)          // before the slow step
let output = try await llm.run(...)                         // slow
try DataGeneration.write(db, expected: generation) { d in   // throws DataGeneration.Stale after a delete-all
    // re-check that the rows you depend on still exist and are still allowed, using `in: d` reads
    try store.insert(output, in: d)
}
```

Catch `DataGeneration.Stale` and drop the result quietly (log a code, not the content).

## Settings

- `SettingsStore` stores JSON values by string key, named `area.name` (`memory.enabled`,
  `llm.routing`, `chat.forgetAt`, `reminders.pendingPrompts`). Keep the key as a `static let` next
  to the type that owns it.
- An unreadable value falls back to the documented default and logs the key name (never the
  value). For anything privacy-related, the fallback is the safe one (off or deny).
- Settings survive delete-all unless `DataReset` clears them. Decide which side each new key is
  on and say so in a comment.

## Delete-all and forget coverage

Any new table or setting holding captured or derived content must be:

1. deleted in `DataReset.deleteAllCapturedData` (one transaction; update its doc comment's list),
2. covered by a `StorageTests` test asserting it is empty after delete-all,
3. cleared or filtered on capture forget if it can quote snapshots (see the privacy skill and
   `ForgetMarks`).

`llm_calls` (cost accounting), exclusions, user time rules and most settings are kept on purpose.

## Performance

Capture writes every few seconds. Per-tick lookups must hit an index (see `v2`); check new
queries with `EXPLAIN QUERY PLAN` in a test when they run on a hot path.

## Checklist

- [ ] New migration (not an edit), literal SQL, idempotent if it repairs, tested.
- [ ] No store call that writes inside another write; `in d:` overloads added where needed.
- [ ] Slow jobs write through `DataGeneration.write(expected:)` and re-check inside it.
- [ ] Delete-all and forget cover the new data, with tests.
- [ ] Setting keys named `area.name`, safe fallback, decided whether delete-all clears it.
