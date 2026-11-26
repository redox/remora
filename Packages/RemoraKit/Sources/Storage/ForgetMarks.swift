import Foundation
import GRDB

/// What a capture forget records in its own transaction (`SnapshotStore.delete(ids:now:in:)`):
/// - `memory.digestDirtySince`: the digest may still name forgotten content. While set, no digest
///   is read for a prompt or an MCP client (`MemoryContext.base`, `get_working_memory`); a stored
///   digest rebuild clears it (`DigestPipeline`).
/// - `chat.forgetAt`: chat turns and fold summaries created before it are never replayed to the
///   model again (they stay visible in the chat until Clear chat).
/// Delete-all clears both (`DataReset`).
public enum ForgetMarks {
    public static let digestDirtyKey = "memory.digestDirtySince"
    public static let chatForgetAtKey = "chat.forgetAt"

    /// Sets both marks to `now` (inside the forget's write).
    public static func mark(now: Date, in d: Database) throws {
        let digest = try SettingsStore.json(now)
        try SettingsStore.store(digest, forKey: digestDirtyKey, in: d)
        try markChat(now: now, in: d)
        // Routine feedback may refer to the forgotten evidence. Candidates are rebuilt from live captures.
        try SettingsStore.store(nil, forKey: RoutineFeedback.settingsKey, in: d)
        try SettingsStore.store(nil, forKey: RoutineFindings.seenKey, in: d)
        try RoutineFindings.clearMessages(in: d)
    }

    /// Imported meetings can appear in chat without contributing to memory compaction.
    public static func markChat(now: Date, in d: Database) throws {
        // Never move the chat watermark back (a forget stamped earlier than a previous one).
        let previous = try? SettingsStore.jsonValue(Date.self, forKey: chatForgetAtKey, in: d)
        let chat = max(previous ?? now, now)
        try SettingsStore.store(try SettingsStore.json(chat), forKey: chatForgetAtKey, in: d)
    }

    /// True while a forget has not been followed by a stored digest rebuild. A mark that cannot be
    /// read counts as dirty (fail closed).
    public static func digestIsDirty(in d: Database) -> Bool {
        do { return try SettingsStore.jsonValue(Date.self, forKey: digestDirtyKey, in: d) != nil } catch { return true }
    }

    /// The chat watermark (nil: no forget since the last delete-all). Unreadable: `.distantFuture`
    /// (replay nothing).
    public static func chatForgetAt(in d: Database) -> Date? {
        do { return try SettingsStore.jsonValue(Date.self, forKey: chatForgetAtKey, in: d) } catch { return .distantFuture }
    }
}
