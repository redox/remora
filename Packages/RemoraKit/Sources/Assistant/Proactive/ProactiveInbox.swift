import Capture
import Foundation
import GRDB
import Redaction
import Retrieval
import Storage
import os

/// Delivers a proactive message (brief, wrap, nudge, reminder) to the chat: the inbox row, its
/// assistant chat turn and the model calls' artifact links, in one transaction. After the commit it
/// calls `onDelivered` (the app reloads the chat and posts the notification). Bodies are model or
/// user text: they are redacted here once more and never logged.
public struct ProactiveInbox: Sendable {
    private let db: AppDatabase
    private let onDelivered: @Sendable (InboxMessage) async -> Void
    private let redactor: Redactor
    private static let log = Logger(subsystem: "dev.remora", category: "proactive")

    public init(db: AppDatabase, onDelivered: @escaping @Sendable (InboxMessage) async -> Void) {
        self.db = db; self.onDelivered = onDelivered; self.redactor = Redactor()
    }

    /// The `DataGeneration` now, for a caller about to start work it will deliver later.
    public func generation() throws -> Int { try DataGeneration.current(db) }

    /// Whether a message with this dedupe key was already delivered.
    public func delivered(dedupeKey: String) throws -> Bool {
        try db.reader.read { d in
            try Bool.fetchOne(d, sql: "SELECT 1 FROM inbox_messages WHERE dedupe_key = ?", arguments: [dedupeKey]) ?? false
        }
    }

    /// In one `DataGeneration.write(expected:)` (a plain write when `expectedGeneration` is nil):
    /// inserts the message (`insertIfNew`, or `insertNudge` under `nudgeCap`), the assistant turn
    /// (`inboxID`, `text = body`, `llmCallIDs`), and points each call at the message. Before
    /// inserting, inside the same transaction, it checks that what the message is about still
    /// exists: the reminder, the flag (still open), and every evidence row with the snapshot ids it
    /// had when read (forget deletes or rewrites them without a generation bump).
    ///
    /// Returns nil, writing nothing, for a duplicate, a hit cap, gone or changed evidence, or a
    /// brief or nudge once proactive messages or background memory are off (re-read inside the
    /// transaction), or whose evidence an exclusion added meanwhile now hides: the exclusions are
    /// loaded fresh (`policy`, default `SnapshotPolicy.current`) after the slow write, outside the
    /// transaction, and every evidence source must keep at least one live allowed snapshot.
    /// Throws `DataGeneration.Stale` after a delete-all. `onStored` runs inside the same
    /// transaction once the message is stored (a nudge records its `sent` decision there).
    public func deliver(kind: InboxKind, title: String, body: String, dedupeKey: String, callIDs: [Int64],
                        flagID: Int64? = nil, reminderID: Int64? = nil, expectedGeneration: Int?,
                        nudgeCap: (cap: Int, minGap: TimeInterval, dayStart: Date)? = nil,
                        evidence: [EvidenceSource] = [], at: Date, policy: CapturePolicy? = nil,
                        onStored: (@Sendable (InboxMessage, Database) throws -> Void)? = nil) async throws -> InboxMessage? {
        // Fresh exclusions, read before (never inside) the write.
        let policy = kind == .reminder ? nil : (policy ?? SnapshotPolicy.current(db))
        let work: (Database) throws -> InboxMessage? = { d in
            let stored = try insert(kind: kind, title: title, body: body, dedupeKey: dedupeKey, callIDs: callIDs,
                                    flagID: flagID, reminderID: reminderID, nudgeCap: nudgeCap, evidence: evidence,
                                    policy: policy, at: at, in: d)
            if let stored { try onStored?(stored, d) }
            return stored
        }
        let stored: InboxMessage?
        if let expectedGeneration {
            stored = try DataGeneration.write(db, expected: expectedGeneration, work)
        } else {
            stored = try db.writer.write(work)
        }
        Self.log.info("deliver \(kind.rawValue, privacy: .public): \(stored == nil ? "skipped" : "stored", privacy: .public)")
        if let stored { await onDelivered(stored) }
        return stored
    }

    /// The transactional part of `deliver`, for a caller already inside a write (a `notify`
    /// reminder is stored in `ReminderEngine.fireDue`'s own transaction). The caller calls
    /// `delivered(_:)` after its commit. nil: duplicate, cap, or gone or changed evidence.
    func insert(kind: InboxKind, title: String, body: String, dedupeKey: String, callIDs: [Int64],
                flagID: Int64? = nil, reminderID: Int64? = nil,
                nudgeCap: (cap: Int, minGap: TimeInterval, dayStart: Date)? = nil,
                evidence: [EvidenceSource] = [], policy: CapturePolicy? = nil, at: Date,
                in d: Database) throws -> InboxMessage? {
        // Proactive or background memory turned off while a brief or nudge was being written: not delivered.
        if kind != .reminder, !Self.proactiveEnabled(db, in: d) || !Self.memoryEnabled(db, in: d) { return nil }
        guard try Self.stillValid(reminderID: reminderID, flagID: flagID, evidence: evidence,
                                  policy: kind == .reminder ? nil : (policy ?? .denyAll), in: d) else { return nil }
        let message = InboxMessage(kind: kind, title: title, body: redactor.redact(body), dedupeKey: dedupeKey,
                                   createdAt: at, reminderID: reminderID, flagID: flagID, llmCallIDs: callIDs)
        let stored: InboxMessage?
        if let nudgeCap {
            stored = try InboxStore(db).insertNudge(message, dailyCap: nudgeCap.cap, minGap: nudgeCap.minGap,
                                                    dayStart: nudgeCap.dayStart, in: d)
        } else {
            stored = try InboxStore.insertIfNew(message, in: d)
        }
        guard let stored, let id = stored.id else { return nil }
        // Model text written from captured evidence: tainted in its own right, not only through
        // `inbox_id` (which delete sets to NULL).
        try ChatStore(db).append(ChatTurn(createdAt: at, role: .assistant, text: stored.body, status: .complete,
                                          llmCallIDs: callIDs, inboxID: id, tainted: true), in: d)
        let calls = LLMCallStore(db)
        for call in callIDs { try calls.setArtifact(callID: call, table: "inbox_messages", id: id, in: d) }
        return stored
    }

    /// After the commit of an `insert`: tells the app (reload, notification).
    func delivered(_ m: InboxMessage) async { await onDelivered(m) }

    var database: AppDatabase { db }

    /// Inside the delivery transaction: the reminder exists, the flag exists and is open, and every
    /// evidence row exists with the same snapshot ids. With a `policy` (briefs and nudges), every
    /// evidence source citing snapshots must still have one that exists and the policy allows
    /// (`DerivedPolicy.allowedIDs`); under `.denyAll` nothing passes.
    static func stillValid(reminderID: Int64?, flagID: Int64?, evidence: [EvidenceSource], policy: CapturePolicy? = nil,
                           in d: Database) throws -> Bool {
        if let policy, policy.deniesEverything { return false }
        if let reminderID, try !Reminder.exists(d, key: reminderID) { return false }
        if let flagID {
            let status = try String.fetchOne(d, sql: "SELECT status FROM salient_flags WHERE id = ?", arguments: [flagID])
            guard status == FlagStatus.open.rawValue else { return false }
        }
        for source in evidence {
            guard allowedTables.contains(source.table),
                  let raw = try String.fetchOne(d, sql: "SELECT snapshot_ids FROM \(source.table) WHERE id = ?",
                                                arguments: [source.id]),
                  let ids = try? JSONDecoder().decode([Int64].self, from: Data(raw.utf8)),
                  Set(ids) == Set(source.snapshotIDs) else { return false }
            if let policy, !source.snapshotIDs.isEmpty,
               try DerivedPolicy.allowedIDs(source.snapshotIDs, policy: policy, in: d).isEmpty { return false }
        }
        return true
    }

    /// `memory.enabled`, read inside the delivery transaction (default on; unreadable: off).
    static func memoryEnabled(_ db: AppDatabase, in d: Database) -> Bool {
        do { return try SettingsStore(db).value(Bool.self, forKey: MemorySettings.enabledKey, in: d) ?? true } catch { return false }
    }

    /// `proactive.enabled`, read inside the delivery transaction (default on).
    static func proactiveEnabled(_ db: AppDatabase, in d: Database) -> Bool {
        (try? SettingsStore(db).value(Bool.self, forKey: SettingRegistry.proactiveEnabledKey, in: d)) ?? true
    }

    static let allowedTables: Set<String> = ["chronicle", "salient_flags", "working_memory"]
}
