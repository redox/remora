import Foundation
import GRDB

/// Sizes and row counts for Settings › Memory status.
public enum DatabaseStats {
    /// Bytes of the database file and of its `-wal` file; 0 for a file that does not exist.
    public static func fileSizes(_ url: URL) -> (main: Int64, wal: Int64) {
        func size(_ path: String) -> Int64 {
            ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
        }
        return (size(url.path), size(url.path + "-wal"))
    }

    /// The tables whose row counts `counts` returns.
    public static let countedTables = ["snapshots", "chronicle", "wiki_pages", "wiki_facts", "salient_flags", "embeddings"]

    /// Row counts by table name (`countedTables`).
    public static func counts(_ db: AppDatabase) throws -> [String: Int] {
        try db.reader.read { d in
            var out: [String: Int] = [:]
            for table in countedTables {
                out[table] = try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
            }
            return out
        }
    }
}
