import Foundation
import GRDB

/// The current identity profile (Task 10's `IdentityStore` conforms), as the digest reads it.
public protocol IdentityReading: Sendable {
    func current() throws -> IdentityRevision?
}

/// Memory digest versions: the newest is current, the newest `keep` are kept.
public struct MemoryDigestStore: Sendable {
    public static let keep = 7
    private let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    public func latest() throws -> MemoryDigest? {
        try db.reader.read { try MemoryDigest.fetchOne($0, sql: "SELECT * FROM memory_digest ORDER BY id DESC LIMIT 1") }
    }

    /// Inserts `digest` (its id is ignored), then deletes all but the newest `keep`. Returns the
    /// stored row. Callers redact and cap the text first.
    @discardableResult
    public func insert(_ digest: MemoryDigest, in d: Database) throws -> MemoryDigest {
        var row = digest
        row.id = nil
        try row.insert(d)
        try d.execute(sql: """
            DELETE FROM memory_digest WHERE id NOT IN (SELECT id FROM memory_digest ORDER BY id DESC LIMIT ?)
            """, arguments: [Self.keep])
        return row
    }
}
