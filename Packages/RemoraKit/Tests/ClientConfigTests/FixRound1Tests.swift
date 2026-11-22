import Foundation
import Testing
@testable import ClientConfig

final class HookedFileManager: FileManager, @unchecked Sendable {
    nonisolated(unsafe) var beforeContents: (@Sendable (Int, String) -> Void)?
    nonisolated(unsafe) var failReplace = false
    private var count = 0

    override func contents(atPath path: String) -> Data? {
        count += 1
        beforeContents?(count, path)
        return super.contents(atPath: path)
    }

    override func replaceItem(at originalItemURL: URL, withItemAt newItemURL: URL, backupItemName: String?,
                              options: FileManager.ItemReplacementOptions = [],
                              resultingItemURL resultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        if failReplace { throw CocoaError(.fileWriteUnknown) }
        try super.replaceItem(at: originalItemURL, withItemAt: newItemURL, backupItemName: backupItemName, options: options, resultingItemURL: resultingURL)
    }
}

@Suite struct FixRound1Tests {
    func names(_ dir: URL) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() }

    // MARK: Backups

    @Test func backupIsRemovedWhenFinalChangedOnDiskCheckFails() throws {
        let home = try makeTempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("c.json")
        try Data("old".utf8).write(to: file)
        let fm = HookedFileManager()
        fm.beforeContents = { n, path in
            if n == 2 { try? Data("edited by the app".utf8).write(to: URL(fileURLWithPath: path)) }
        }
        let w = SafeFileWriter(now: steppingClock(), fileManager: fm)
        #expect(throws: ConfigError.changedOnDisk) {
            try w.write(Data("new".utf8), to: file.resolvingSymlinksInPath(), expectedOriginal: Data("old".utf8))
        }
        #expect(read(file) == "edited by the app")
        #expect(try names(home) == ["c.json"])
    }

    @Test func backupAndTempAreRemovedWhenSwapFails() throws {
        let home = try makeTempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("c.json")
        try Data("old".utf8).write(to: file)
        let fm = HookedFileManager()
        fm.failReplace = true
        let w = SafeFileWriter(now: steppingClock(), fileManager: fm)
        #expect(throws: ConfigError.self) {
            try w.write(Data("new".utf8), to: file.resolvingSymlinksInPath(), expectedOriginal: Data("old".utf8))
        }
        #expect(read(file) == "old")
        #expect(try names(home) == ["c.json"])
    }

    @Test func pruneKeepsNewestEvenWhenNumberedNamesSortOddly() throws {
        let home = try makeTempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("c.json")
        try Data("v0".utf8).write(to: file)
        // A frozen clock makes every backup share one timestamp: names go -2 … -12 ("-10" < "-2" as text).
        let w = SafeFileWriter(now: { Date(timeIntervalSince1970: 1_700_000_000) })
        var last: URL?
        for i in 1...12 {
            let (data, resolved) = try w.read(file)
            last = try w.write(Data("v\(i)".utf8), to: resolved, expectedOriginal: data)
        }
        let kept = try names(home).filter { $0.contains("remora-backup") }
        #expect(kept.count == 3)
        #expect(Set(kept.map { read(home.appendingPathComponent($0)) }) == ["v9", "v10", "v11"])
        #expect(FileManager.default.fileExists(atPath: last!.path))
        #expect(read(last!) == "v11")
    }

    // MARK: JSON editor

    @Test func upsertThatChangesNothingReturnsTheOriginalBytes() throws {
        let entry: OrderedJSON = .object([("command", .string("/p")), ("args", .array([]))])
        let src = Data(#"{"mcpServers":{"remora":{"command":"/p","args":[]}},"x":1.0}"#.utf8)
        #expect(try JSONConfigEditor.upsertServer(in: src, entry: entry) == src)
        let changed = try JSONConfigEditor.upsertServer(in: src, entry: .object([("command", .string("/q"))]))
        #expect(changed != src)
    }

    @Test func registrarDoesNotWriteWhenEditIsANoOp() async throws {
        let home = try makeTempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let file = MCPClient.cursor.configURL(home: home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Same command, different args: status says connected, so connect must leave the file alone.
        let src = #"{"mcpServers":{"remora":{"command":"/S","args":["--x"]}}}"#
        try Data(src.utf8).write(to: file)
        let r = makeRegistrar(home: home, serverPath: "/S")
        #expect(await r.connect(.cursor) == .done(backup: nil))
        #expect(read(file) == src)
        #expect(try names(file.deletingLastPathComponent()) == ["mcp.json"])
    }

    // MARK: TOML

    @Test func duplicateRemoraTableIsRefused() {
        let t = "[mcp_servers.remora]\ncommand = \"/a\"\n\n[mcp_servers.\"remora\"]\ncommand = \"/b\"\n"
        let expected = ConfigError.unsupportedTOML("duplicate remora table")
        #expect(throws: expected) { try CodexTOML.serverCommand(in: t) }
        #expect(throws: expected) { try CodexTOML.appendServer(to: t, command: "/p") }
        #expect(throws: expected) { try CodexTOML.removeServer(from: t) }
    }

    @Test func crlfRemoveDropsOnlyOurTableAndKeepsLineEnds() throws {
        let base = "a = 1\r\n"
        let added = try CodexTOML.appendServer(to: base, command: "/p")
        #expect(try CodexTOML.removeServer(from: added) == base)
        let middle = "a = 1\r\n\r\n[mcp_servers.remora]\r\ncommand = \"/p\"\r\n\r\n[x]\r\nb = 2\r\n"
        #expect(try CodexTOML.removeServer(from: middle) == "a = 1\r\n\r\n[x]\r\nb = 2\r\n")
    }

    // MARK: JSON depth

    @Test func depthBoundary() throws {
        func nested(_ n: Int) -> Data { Data((String(repeating: "[", count: n) + String(repeating: "]", count: n)).utf8) }
        _ = try OrderedJSON.parse(nested(63))
        #expect(throws: ConfigError.self) { try OrderedJSON.parse(nested(64)) }
    }

    // MARK: Locator

    @Test func loginShellAnswerThatIsARelativeNameIsRejected() async {
        let home = URL(fileURLWithPath: "/H", isDirectory: true)
        // The lookup answers the very name that was asked for, and a file by that bare name "exists".
        let l = ExecutableLocator(home: home, fileExists: { $0 == "claude" }, loginShellLookup: { name in name })
        #expect(await l.find("claude") == nil)
    }
}
