import Foundation
import GRDB
import Testing
@testable import Storage

@Test func fileSizesReadMainAndWal() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appending(path: "stats.sqlite")
    let db = try AppDatabase.open(at: url)
    _ = try SnapshotStore(db).insert(.fixture(text: "hello world"))
    let sizes = DatabaseStats.fileSizes(url)
    #expect(sizes.main > 0)
    #expect(sizes.wal > 0)
    let missing = DatabaseStats.fileSizes(dir.appending(path: "absent.sqlite"))
    #expect(missing.main == 0 && missing.wal == 0)
}

@Test func countsCoverTheMemoryTables() throws {
    let db = try AppDatabase.inMemory()
    _ = try SnapshotStore(db).insert(.fixture(text: "one"))
    _ = try SnapshotStore(db).insert(.fixture(text: "two"))
    try seedMemoryRows(db)
    let counts = try DatabaseStats.counts(db)
    #expect(counts == ["snapshots": 2, "chronicle": 1, "wiki_pages": 1, "wiki_facts": 1, "salient_flags": 1,
                       "embeddings": 1])
}
