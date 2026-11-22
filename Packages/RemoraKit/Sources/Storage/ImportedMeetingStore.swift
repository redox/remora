import CryptoKit
import Foundation
import GRDB

public struct MeetingSource: Codable, Equatable, Identifiable, Sendable {
    public enum Provider: String, Codable, CaseIterable, Sendable {
        case quill, granola, compatible

        public var title: String {
            switch self {
            case .quill: "Quill Meetings"
            case .granola: "Granola"
            case .compatible: "Local MCP"
            }
        }
    }

    public let id: UUID
    public let provider: Provider
    public let endpoint: String
    public let initialSince: Date?

    public init(provider: Provider, endpoint: String, initialSince: Date? = nil) {
        self.id = UUID()
        self.provider = provider
        self.endpoint = endpoint
        self.initialSince = initialSince
    }
}

public struct ImportedMeeting: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord, Identifiable {
    public let sourceID: UUID
    public let remoteID: String
    public let startedAt: Date
    public var title: String
    public var body: String

    public var id: String { "\(sourceID.uuidString)/\(remoteID)" }
    public static let databaseTableName = "imported_meetings"
    enum CodingKeys: String, CodingKey {
        case sourceID = "source_id"
        case remoteID = "remote_id"
        case startedAt = "started_at"
        case title, body
    }

    public init(sourceID: UUID, remoteID: String, startedAt: Date, title: String, body: String) {
        self.sourceID = sourceID
        self.remoteID = remoteID
        self.startedAt = startedAt
        self.title = title
        self.body = body
    }
}

public struct ImportedMeetingStore: Sendable {
    public enum WriteResult: Equatable, Sendable { case saved, unchanged, skipped }

    // Delete-all disconnects sources, so a scheduled import cannot refill the database.
    static let sourcesKey = "meetingImport.sources"
    static let chatKey = "meetingImport.chatAccess"
    static let syncDatesKey = "meetingImport.syncDates"
    private let db: AppDatabase

    public init(_ db: AppDatabase) { self.db = db }

    public func sources() throws -> [MeetingSource] {
        try db.reader.read { try Self.sources(in: $0) }
    }

    public func save(_ source: MeetingSource) throws {
        try db.writer.write { d in
            var all = try Self.sources(in: d)
            if !all.contains(source) { all.append(source) }
            try SettingsStore(db).setValue(all, forKey: Self.sourcesKey, in: d)
        }
    }

    public func chatAccessEnabled() throws -> Bool {
        try SettingsStore(db).value(Bool.self, forKey: Self.chatKey) == true
    }

    public func setChatAccessEnabled(_ enabled: Bool, now: Date = Date()) throws {
        try db.writer.write { d in
            let settings = SettingsStore(db)
            try settings.setValue(enabled, forKey: Self.chatKey, in: d)
            if !enabled { try ForgetMarks.markChat(now: now, in: d) }
        }
    }

    public func lastSyncDate(for source: MeetingSource) throws -> Date? {
        try SettingsStore(db).value([UUID: Date].self, forKey: Self.syncDatesKey)?[source.id]
    }

    public func recordSync(_ source: MeetingSource, at date: Date, generation: Int) throws {
        try DataGeneration.write(db, expected: generation) { d in
            guard try Self.sources(in: d).contains(source),
                  try !SettingsStore.isPausedFailClosed(d, now: date) else { return }
            let settings = SettingsStore(db)
            var dates = try settings.value([UUID: Date].self, forKey: Self.syncDatesKey, in: d) ?? [:]
            dates[source.id] = date
            try settings.setValue(dates, forKey: Self.syncDatesKey, in: d)
        }
    }

    public func disconnect(_ source: MeetingSource) throws {
        try db.writer.write { d in
            let remaining = try Self.sources(in: d).filter { $0.id != source.id }
            let settings = SettingsStore(db)
            try settings.setValue(remaining, forKey: Self.sourcesKey, in: d)
            var dates = try settings.value([UUID: Date].self, forKey: Self.syncDatesKey, in: d) ?? [:]
            dates.removeValue(forKey: source.id)
            try settings.setValue(dates, forKey: Self.syncDatesKey, in: d)
            try d.execute(sql: "DELETE FROM imported_meetings WHERE source_id = ?", arguments: [source.id])
            if d.changesCount > 0 { try ForgetMarks.markChat(now: Date(), in: d) }
            if remaining.isEmpty { try settings.setValue(false, forKey: Self.chatKey, in: d) }
        }
    }

    public func write(
        _ meeting: ImportedMeeting, source: MeetingSource, generation: Int, now: Date,
        isAllowed: ([String]) -> Bool = { _ in true }
    ) throws -> WriteResult {
        try DataGeneration.write(db, expected: generation) { d in
            guard meeting.sourceID == source.id,
                  try Self.sources(in: d).contains(source),
                  try !SettingsStore.isPausedFailClosed(d, now: now),
                  try isAllowed(ExclusionStore.all(in: d)),
                  try !Self.isForgotten(meeting.remoteID, source: source, in: d) else { return .skipped }
            let existing = try ImportedMeeting.fetchOne(d, key: ["source_id": meeting.sourceID,
                                                                 "remote_id": meeting.remoteID])
            if let existing, existing.title == meeting.title, existing.body == meeting.body,
               abs(existing.startedAt.timeIntervalSince(meeting.startedAt)) < 0.001 {
                return .unchanged
            }
            try meeting.save(d)
            return .saved
        }
    }

    public func isForgotten(_ remoteID: String, source: MeetingSource) throws -> Bool {
        try db.reader.read { try Self.isForgotten(remoteID, source: source, in: $0) }
    }

    public func forget(_ meeting: ImportedMeeting) throws {
        try db.writer.write { d in
            guard let source = try Self.sources(in: d).first(where: { $0.id == meeting.sourceID }) else { return }
            try d.execute(sql: "INSERT OR IGNORE INTO forgotten_imports (digest) VALUES (?)",
                          arguments: [Self.fingerprint(meeting.remoteID, source: source)])
            if try ImportedMeeting.deleteOne(d, key: ["source_id": meeting.sourceID, "remote_id": meeting.remoteID]) {
                try ForgetMarks.markChat(now: Date(), in: d)
            }
        }
    }

    public func search(_ query: String, limit: Int = 100) throws -> [ImportedMeeting] {
        guard limit > 0 else { return [] }
        if let match = FTSQuery.make(from: query) {
            return try db.reader.read { d in
                try ImportedMeeting.fetchAll(d, sql: """
                    SELECT m.* FROM imported_meetings_fts JOIN imported_meetings m
                    ON m.rowid = imported_meetings_fts.rowid
                    WHERE imported_meetings_fts MATCH ? ORDER BY rank, m.started_at DESC LIMIT ?
                    """, arguments: [match, limit])
            }
        }
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return try db.reader.read { d in
            try ImportedMeeting.order(Column("started_at").desc).limit(limit).fetchAll(d)
        }
    }

    private static func sources(in d: Database) throws -> [MeetingSource] {
        try SettingsStore.jsonValue([MeetingSource].self, forKey: sourcesKey, in: d) ?? []
    }

    private static func isForgotten(_ remoteID: String, source: MeetingSource, in d: Database) throws -> Bool {
        try Bool.fetchOne(d, sql: "SELECT 1 FROM forgotten_imports WHERE digest = ?",
                          arguments: [fingerprint(remoteID, source: source)]) ?? false
    }

    private static func fingerprint(_ remoteID: String, source: MeetingSource) -> Data {
        // Provider IDs survive reconnects and, for Quill, changes to its listening port.
        let namespace = source.provider == .compatible ? source.endpoint : source.provider.rawValue
        return Data(SHA256.hash(data: Data("\(namespace.utf8.count):\(namespace)\(remoteID)".utf8)))
    }
}
