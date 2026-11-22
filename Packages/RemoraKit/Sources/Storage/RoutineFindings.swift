import Foundation
import GRDB

/// Automatic routine findings are inbox nudges. The prefix identifies their local-only chat
/// turns and the setting records which fingerprints were already surfaced.
public enum RoutineFindings {
    public static let inboxKeyPrefix = "routines:"
    public static let seenKey = "routines.seenFindings"
    static let inboxKeyPattern = inboxKeyPrefix + "*"

    /// A new exclusion or forget can invalidate a previously shown finding. Clear the chat rows
    /// before their inbox rows so a foreign-key update cannot leave the old text visible.
    static func clearMessages(in d: Database) throws {
        try d.execute(sql: """
            DELETE FROM chat_turns WHERE inbox_id IN (SELECT id FROM inbox_messages WHERE dedupe_key GLOB ?)
            """, arguments: [inboxKeyPattern])
        try d.execute(sql: "DELETE FROM inbox_messages WHERE dedupe_key GLOB ?", arguments: [inboxKeyPattern])
    }

    static func pruneSeen(olderThan cutoff: Date, in d: Database) throws {
        guard let seen = try? SettingsStore.jsonValue([String: Date].self, forKey: seenKey, in: d) else { return }
        let kept = seen.filter { $0.value >= cutoff }
        if kept.count != seen.count {
            try SettingsStore.store(try SettingsStore.json(kept.isEmpty ? nil : kept), forKey: seenKey, in: d)
        }
    }
}
