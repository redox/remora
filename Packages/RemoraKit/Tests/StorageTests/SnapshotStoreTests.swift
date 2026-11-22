import Foundation
import Testing
@testable import Storage

@Test func searchIsAccentInsensitive() throws {
    let store = SnapshotStore(try .inMemory())
    _ = try store.insert(.fixture(text: "Résumé de la réunion d'été avec Zoé"))
    #expect(try store.search("ete").count == 1)
    #expect(try store.search("REUNION zoe").count == 1)
}

@Test func searchMatchesPrefixes() throws {
    let store = SnapshotStore(try .inMemory())
    _ = try store.insert(.fixture(text: "Quarterly project review"))
    #expect(try store.search("proj").count == 1)
}

@Test(arguments: ["C++ & \"foo", "-", "AND OR NOT", "a:b", "🐟", "   ", "\"unterminated", "col:val*"])
func searchSanitizesOperators(_ q: String) throws {
    let store = SnapshotStore(try .inMemory())
    _ = try store.insert(.fixture(text: "C++ foo"))
    _ = try store.search(q)   // must not throw
}

@Test func searchFiltersByAppAndTime() throws {
    let store = SnapshotStore(try .inMemory())
    let early = Date(timeIntervalSince1970: 1_000), late = Date(timeIntervalSince1970: 2_000)
    _ = try store.insert(.fixture(text: "shared budget", app: "Notes", capturedAt: early))
    _ = try store.insert(.fixture(text: "shared budget", app: "Mail", capturedAt: late))
    #expect(try store.search("budget").count == 2)
    #expect(try store.search("budget", app: "Mail").map(\.app) == ["Mail"])
    #expect(try store.search("budget", since: Date(timeIntervalSince1970: 1_500)).map(\.app) == ["Mail"])
    #expect(try store.search("budget", until: Date(timeIntervalSince1970: 1_500)).map(\.app) == ["Notes"])
}

@Test func searchReturnsSnippetWithMarkers() throws {
    let store = SnapshotStore(try .inMemory())
    _ = try store.insert(.fixture(text: "the quick brown fox"))
    #expect(try store.search("quick").first?.snippet.contains("[quick]") == true)
}

@Test func latestHashIsPerAppAndTitle() throws {
    let store = SnapshotStore(try .inMemory())
    var a = Snapshot.fixture(text: "one", app: "Slack", windowTitle: "#general"); a.contentHash = "H-general"
    var b = Snapshot.fixture(text: "two", app: "Slack", windowTitle: "#random",
                             capturedAt: Date(timeIntervalSince1970: 1_000_100)); b.contentHash = "H-random"
    _ = try store.insert(a); _ = try store.insert(b)
    #expect(try store.latestHash(app: "Slack", windowTitle: "#general") == "H-general")
    #expect(try store.latestHash(app: "Slack", windowTitle: "#random") == "H-random")
    #expect(try store.latestHash(app: "Slack", windowTitle: "#none") == nil)
    #expect(try store.latestHash(app: "Slack", windowTitle: nil) == nil)
}

@Test func deleteAllEmptiesTablesAndIndex() throws {
    let db = try AppDatabase.inMemory()
    let store = SnapshotStore(db)
    _ = try store.insert(.fixture(text: "x marks the spot"))
    #expect(try store.search("x").count == 1)
    try store.deleteAll()
    #expect(try store.search("x") == [])
    #expect(try db.reader.read { try Snapshot.fetchCount($0) } == 0)
}

@Test func insertReturnsIDAndFetchHelpersWork() throws {
    let store = SnapshotStore(try .inMemory())
    let a = try store.insert(.fixture(text: "alpha", app: "A", capturedAt: Date(timeIntervalSince1970: 10)))
    let b = try store.insert(.fixture(text: "beta", app: "A", capturedAt: Date(timeIntervalSince1970: 20)))
    #expect(a.id != nil && b.id != nil && a.id != b.id)
    #expect(try store.snapshots(ids: [b.id!, a.id!]).count == 2)
    let s = try store.session(app: "A", from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 15), limit: 10)
    #expect(s.map(\.text) == ["alpha"])
    #expect(try store.recent(limit: 1).map(\.id) == [b.id!])
}

@Test func readOnlyReaderSeesCommittedWritesConcurrently() throws {
    let url = tempDir().appending(path: "r.sqlite")
    let rw = try AppDatabase.open(at: url); let ro = try AppDatabase.openReadOnly(at: url)
    _ = try SnapshotStore(rw).insert(.fixture(text: "hello world"))
    #expect(try SnapshotStore(ro).search("hello").count == 1)
    #expect(throws: (any Error).self) { try SnapshotStore(ro).insert(.fixture(text: "nope")) }
}

@Test func openReadOnlyThrowsWhenMissing() {
    let url = tempDir().appending(path: "missing.sqlite")
    #expect(throws: (any Error).self) { try AppDatabase.openReadOnly(at: url) }
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func schemaHasExpectedTablesAndFTSOptions() throws {
    let db = try AppDatabase.inMemory()
    let (names, sql) = try db.reader.read { d -> ([String], String) in
        (try String.fetchAll(d, sql: "SELECT name FROM sqlite_master WHERE type='table'"),
         try String.fetchOne(d, sql: "SELECT sql FROM sqlite_master WHERE name='snapshots_fts'") ?? "")
    }
    for t in ["snapshots", "snapshots_fts", "activity_events", "exclusions", "settings"] {
        #expect(names.contains(t))
    }
    #expect(sql.contains("remove_diacritics"))
    #expect(sql.contains("prefix"))
}

@Test func latestHashFiltersBySource() throws {
    let db = try AppDatabase.inMemory()
    let store = SnapshotStore(db)
    var ax = Snapshot.fixture(text: "window text", windowTitle: "W"); ax.contentHash = "ax-hash"
    var clip = Snapshot.fixture(text: "clip text", windowTitle: "W",
                                capturedAt: Date(timeIntervalSince1970: 1_000_100))
    clip.contentHash = "clip-hash"; clip.source = .clipboard
    _ = try store.insert(ax); _ = try store.insert(clip)
    #expect(try store.latestHash(app: "Notes", windowTitle: "W", source: .ax) == "ax-hash")
    #expect(try store.latestHash(app: "Notes", windowTitle: "W", source: .clipboard) == "clip-hash")
    #expect(try store.latestHash(app: "Notes", windowTitle: "Other", source: .ax) == nil)
}

@Test func searchAnyExcludesCurrentWindow() throws {
    let s = SnapshotStore(try .inMemory())
    _ = try s.insert(.fixture(text: "meeting in oslo", app: "Mail", windowTitle: "Re: Oslo"))
    _ = try s.insert(.fixture(text: "oslo trip plans", app: "Slack", windowTitle: "#oslo"))
    _ = try s.insert(.fixture(text: "oslo other mail", app: "Mail", windowTitle: "Other"))
    #expect(try s.searchAny(terms: ["oslo"]).count == 3)
    let hits = try s.searchAny(terms: ["oslo", "zzz"], excludingApp: "Mail", excludingTitle: "Re: Oslo")
    #expect(Set(hits.map(\.app)) == ["Slack", "Mail"] && hits.count == 2)
    #expect(!hits.contains { $0.windowTitle == "Re: Oslo" })
    #expect(try s.searchAny(terms: ["oslo"], since: Date(timeIntervalSince1970: 2_000_000)).isEmpty)
    #expect(try s.searchAny(terms: ["", "-"]).isEmpty)
    #expect(try s.searchAny(terms: ["oslo"], limit: 1).count == 1)
}
