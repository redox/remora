import Foundation
import GRDB

public enum SnapshotSource: String, Codable, Sendable { case ax, clipboard }

public struct Snapshot: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var capturedAt: Date
    public var app: String
    public var bundleID: String?
    public var windowTitle: String?
    public var url: String?
    public var domain: String?
    public var filePath: String?
    public var text: String
    public var contentHash: String
    public var source: SnapshotSource
    /// When the row was first written. `capturedAt` is the latest update for a rolled row;
    /// nil only for rows read from a pre-v2 database (treat as `capturedAt`).
    public var firstCapturedAt: Date?

    public init(id: Int64? = nil, capturedAt: Date, app: String, bundleID: String? = nil,
                windowTitle: String? = nil, url: String? = nil, domain: String? = nil,
                filePath: String? = nil, text: String, contentHash: String, source: SnapshotSource,
                firstCapturedAt: Date? = nil) {
        self.id = id; self.capturedAt = capturedAt; self.app = app; self.bundleID = bundleID
        self.windowTitle = windowTitle; self.url = url; self.domain = domain
        self.filePath = filePath; self.text = text; self.contentHash = contentHash
        self.source = source
        self.firstCapturedAt = firstCapturedAt ?? capturedAt
    }

    public static let databaseTableName = "snapshots"

    enum CodingKeys: String, CodingKey {
        case id
        case capturedAt = "captured_at"
        case app
        case bundleID = "bundle_id"
        case windowTitle = "window_title"
        case url, domain
        case filePath = "file_path"
        case text
        case contentHash = "content_hash"
        case source
        case firstCapturedAt = "first_captured_at"
    }

    /// Every insert path records the creation time.
    public mutating func willInsert(_ db: Database) throws {
        if firstCapturedAt == nil { firstCapturedAt = capturedAt }
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct SnapshotHit: Codable, Sendable, Equatable {
    public var id: Int64
    public var capturedAt: Date
    public var app: String
    public var windowTitle: String?
    public var domain: String?
    public var snippet: String

    public init(id: Int64, capturedAt: Date, app: String, windowTitle: String?, domain: String?, snippet: String) {
        self.id = id; self.capturedAt = capturedAt; self.app = app
        self.windowTitle = windowTitle; self.domain = domain; self.snippet = snippet
    }
}
