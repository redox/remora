import Foundation
import GRDB

/// Each reader needs its own grant. Delete-all clears both grants with the recordings.
public enum RecordingSearchAccess: String, CaseIterable, Sendable {
    case chat = "meetingRecording.chatAccess"
    case mcp = "meetingRecording.mcpAccess"

    public func enabled(in db: AppDatabase) throws -> Bool {
        try db.reader.read { try enabled(in: $0) }
    }

    public func enabled(in d: Database) throws -> Bool {
        try SettingsStore.jsonValue(Bool.self, forKey: rawValue, in: d) == true
    }

    public func allows(in d: Database, now: Date) throws -> Bool {
        try enabled(in: d) && !SettingsStore.isPausedFailClosed(d, now: now)
    }

    public func set(_ enabled: Bool, in db: AppDatabase, now: Date = Date()) throws {
        try db.writer.write { d in
            try SettingsStore(db).setValue(enabled, forKey: rawValue, in: d)
            if self == .chat && !enabled { try ForgetMarks.markChat(now: now, in: d) }
        }
    }
}
