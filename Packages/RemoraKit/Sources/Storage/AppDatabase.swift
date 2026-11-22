import Foundation
import GRDB

public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter
    public let reader: any DatabaseReader

    private init(writer: any DatabaseWriter, reader: any DatabaseReader) {
        self.writer = writer
        self.reader = reader
    }

    /// `~/Library/Application Support/Remora/remora.sqlite`
    public static var defaultURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "Remora", directoryHint: .isDirectory)
            .appending(path: "remora.sqlite")
    }

    /// Opens (creating if needed) a WAL-mode database and runs migrations.
    public static func open(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: url.path, configuration: config)  // DatabasePool enables WAL
        try Migrations.make().migrate(pool)
        return AppDatabase(writer: pool, reader: pool)
    }

    /// Opens an existing database read-only. Never creates or migrates.
    ///
    /// Used by the MCP server, which runs while the app is writing (WAL) or after the app quit.
    /// A plain read-only connection to a WAL database fails with SQLITE_CANTOPEN when the `-shm`
    /// file is absent (clean shutdown removes `-wal`/`-shm`) and cannot be created, so on
    /// CANTOPEN we retry with `immutable=1`. Immutable mode ignores `-wal` entirely, so the retry
    /// is taken ONLY when `-wal` is absent or empty (clean shutdown: everything is in the main
    /// file). If a non-empty `-wal` exists (e.g. after a crash) the original error is rethrown
    /// rather than silently serving data that misses committed frames.
    public static func openReadOnly(at url: URL, busyTimeout: TimeInterval = 2) throws -> AppDatabase {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DatabaseError(resultCode: .SQLITE_CANTOPEN, message: "database does not exist")
        }
        func make(path: String) throws -> AppDatabase {
            var config = Configuration()
            config.readonly = true
            config.busyMode = .timeout(busyTimeout)
            config.prepareDatabase { db in try db.execute(sql: "PRAGMA query_only = ON") }
            let queue = try DatabaseQueue(path: path, configuration: config)
            // Force the first real read now so open failures surface here, not on first use.
            try queue.read { try $0.execute(sql: "SELECT 1 FROM sqlite_master LIMIT 1") }
            return AppDatabase(writer: queue, reader: queue)
        }
        do {
            return try make(path: url.path)
        } catch let e as DatabaseError where e.resultCode == .SQLITE_CANTOPEN {
            let walPath = url.path + "-wal"
            let walSize = (try? FileManager.default.attributesOfItem(atPath: walPath)[.size] as? Int) ?? nil
            guard walSize == nil || walSize == 0 else { throw e }
            var components = URLComponents()
            components.scheme = "file"
            components.path = url.path
            components.queryItems = [URLQueryItem(name: "immutable", value: "1")]
            guard let uri = components.string else { throw e }
            return try make(path: uri)
        }
    }

    public static func inMemory() throws -> AppDatabase {
        let queue = try DatabaseQueue()
        try Migrations.make().migrate(queue)
        return AppDatabase(writer: queue, reader: queue)
    }
}
