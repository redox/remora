import Foundation
import Testing
@testable import ClientConfig

@Suite struct ClientRegistrarTests {
    let serverPath = "/Apps/Remora.app/Contents/MacOS/remora-mcp"
    let desktopID = "com.anthropic.claudefordesktop"
    let cursorID = "com.todesktop.230313mzl4w4u92"

    func write(_ s: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(s.utf8).write(to: url)
    }

    func entryCommand(_ url: URL) throws -> String? {
        guard let data = FileManager.default.contents(atPath: url.path),
              case .object(let pairs)? = try JSONConfigEditor.server(in: data) else { return nil }
        for case ("command", .string(let c)) in pairs { return c }
        return nil
    }

    @Test func pinnedConfigLocationsAndMetadata() {
        let home = URL(fileURLWithPath: "/H", isDirectory: true)
        #expect(MCPClient.claudeCode.configURL(home: home).path == "/H/.claude.json")
        #expect(MCPClient.claudeDesktop.configURL(home: home).path == "/H/Library/Application Support/Claude/claude_desktop_config.json")
        #expect(MCPClient.cursor.configURL(home: home).path == "/H/.cursor/mcp.json")
        #expect(MCPClient.codex.configURL(home: home).path == "/H/.codex/config.toml")
        #expect(MCPClient.allCases.map(\.displayName) == ["Claude Code", "Claude Desktop", "Cursor", "Codex"])
        #expect(MCPClient.claudeDesktop.appBundleIDs == [desktopID])
        #expect(MCPClient.cursor.appBundleIDs == [cursorID])
        #expect(MCPClient.claudeCode.appBundleIDs.isEmpty && MCPClient.codex.appBundleIDs.isEmpty)
    }

    @Test func claudeDesktopConnectCreatesFileWhenInstalled() async throws {
        let home = try makeTempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let r = makeRegistrar(home: home, installedApps: [desktopID])
        #expect(await r.status(.claudeDesktop) == .notConnected)
        let outcome = await r.connect(.claudeDesktop)
        #expect(outcome == .done(backup: nil))
        let file = MCPClient.claudeDesktop.configURL(home: home)
        #expect(try entryCommand(file) == serverPath)
        let json = try OrderedJSON.parse(Data(read(file).utf8))
        #expect(json == .object([("mcpServers", .object([("remora", .object([("command", .string(serverPath)), ("args", .array([]))]))]))]))
        #expect(await r.status(.claudeDesktop) == .connected)
    }

    @Test func cursorConnectCreatesDirectoryOnlyWhenAppInstalled() async throws {
        let home = try makeTempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let none = makeRegistrar(home: home)
        #expect(await none.connect(.cursor) != .done(backup: nil))
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".cursor").path))
        let r = makeRegistrar(home: home, installedApps: [cursorID])
        #expect(await r.connect(.cursor) == .done(backup: nil))
        #expect(try entryCommand(MCPClient.cursor.configURL(home: home)) == serverPath)
    }

    @Test func notInstalledWhenNothingPresent() async throws {
        let home = try makeTempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let r = makeRegistrar(home: home)
        for c in MCPClient.allCases { #expect(await r.status(c) == .notInstalled) }
        for c in MCPClient.allCases {
            if case .failed = await r.connect(c) {} else { Issue.record("connect should fail for \(c)") }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.path).isEmpty)
    }

    @Test func installedByConfigDirectory() async throws {
        let home = try makeTempHome(); defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".cursor"), withIntermediateDirectories: true)
        let r = makeRegistrar(home: home)
        #expect(await r.status(.codex) == .notConnected)
        #expect(await r.status(.cursor) == .notConnected)
        #expect(await r.status(.claudeCode) == .notInstalled)
    }

    @Test func claudeCodeUsesCLIWhenFound() async throws {
        let home = try makeTempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let cli = FakeClaudeCLI()
        let r = makeRegistrar(home: home, runner: cli.runner, cliPaths: ["/opt/homebrew/bin/claude"])
        #expect(await r.status(.claudeCode) == .notConnected)
        #expect(await r.connect(.claudeCode) == .done(backup: nil))
        #expect(cli.runner.calls.filter { $0[1] != "get" } == [["mcp", "add", "--scope", "user", "remora", serverPath]])
        #expect(cli.runner.executables.allSatisfy { $0 == "/opt/homebrew/bin/claude" })
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.path).isEmpty)
        #expect(await r.status(.claudeCode) == .connected)
    }

    @Test(arguments: ["Local config", "Project config", "", "User configuration unknown"])
    func claudeCodeDoesNotMutateAnEntryOutsideTheVerifiedUserScope(_ scope: String) async throws {
        let home = try makeTempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let path = serverPath
        let runner = FakeRunner { _ in
            CommandResult(status: 0, stdout: "Scope: \(scope)\nCommand: \(path)\n", stderr: "")
        }
        let registrar = makeRegistrar(home: home, runner: runner, cliPaths: ["/opt/homebrew/bin/claude"])
        guard case .cannotEdit = await registrar.status(.claudeCode),
              case .failed = await registrar.connect(.claudeCode),
              case .failed = await registrar.disconnect(.claudeCode) else {
            Issue.record("Only a verified user-scope entry may be changed")
            return
        }
        #expect(runner.calls.allSatisfy { $0 == ["mcp", "get", "remora"] })
    }

    @Test(arguments: ["User config", "User config (available in all your projects)"])
    func claudeCodeRecognizesUserScopeWithOrWithoutAnExplanation(_ scope: String) async throws {
        let home = try makeTempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let path = serverPath
        let runner = FakeRunner { _ in
            CommandResult(status: 0, stdout: "Scope: \(scope)\nCommand: \(path)\n", stderr: "")
        }
        let registrar = makeRegistrar(home: home, runner: runner, cliPaths: ["/opt/homebrew/bin/claude"])
        #expect(await registrar.status(.claudeCode) == .connected)
    }

    @Test func claudeCodeCLIRemovesStaleEntryFirst() async throws {
        let home = try makeTempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let cli = FakeClaudeCLI(registered: "/Old/remora-mcp")
        let r = makeRegistrar(home: home, runner: cli.runner, cliPaths: ["/opt/homebrew/bin/claude"])
        #expect(await r.status(.claudeCode) == .connectedElsewhere(command: "/Old/remora-mcp"))
        #expect(await r.connect(.claudeCode) == .done(backup: nil))
        #expect(cli.runner.calls.filter { $0[1] != "get" } == [["mcp", "remove", "--scope", "user", "remora"], ["mcp", "add", "--scope", "user", "remora", serverPath]])
    }

    @Test func cliSuccessThatDoesNotConnectIsAFailure() async throws {
        let home = try makeTempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let cli = FakeClaudeCLI(addIsNoOp: true)
        let r = makeRegistrar(home: home, runner: cli.runner, cliPaths: ["/opt/homebrew/bin/claude"])
        if case .failed = await r.connect(.claudeCode) {} else { Issue.record("expected failure") }
    }

    @Test func hugeClaudeJSONWithCLIConnectsAndReportsStatus() async throws {
        let home = try makeTempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let file = MCPClient.claudeCode.configURL(home: home)
        let huge = "{\"projects\":\"" + String(repeating: "x", count: 10 * 1024 * 1024) + "\"}"
        try write(huge, to: file)
        let cli = FakeClaudeCLI()
        let r = makeRegistrar(home: home, runner: cli.runner, cliPaths: ["/opt/homebrew/bin/claude"])
        #expect(await r.status(.claudeCode) == .notConnected)
        #expect(await r.connect(.claudeCode) == .done(backup: nil))
        #expect(await r.status(.claudeCode) == .connected)
        #expect(await r.disconnect(.claudeCode) == .done(backup: nil))
        #expect(await r.status(.claudeCode) == .notConnected)
        #expect(read(file) == huge)
    }

    @Test func hugeClaudeJSONWithoutCLIIsNeverEdited() async throws {
        let home = try makeTempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let file = MCPClient.claudeCode.configURL(home: home)
        // Not JSON at all: status can't read it.
        let junk = String(repeating: "not json ", count: 1_200_000)
        try write(junk, to: file)
        let r = makeRegistrar(home: home)
        guard case .cannotEdit = await r.status(.claudeCode) else { Issue.record("expected cannotEdit"); return }
        guard case .failed = await r.connect(.claudeCode) else { Issue.record("expected failure"); return }
        #expect(read(file) == junk)
        // Valid JSON over the 5 MB write cap: readable for status, but never rewritten (Task 12:
        // the status says to install the CLI instead of offering a Connect that would fail).
        let big = "{\"projects\":\"" + String(repeating: "x", count: 10 * 1024 * 1024) + "\"}"
        try write(big, to: file)
        #expect(await r.status(.claudeCode) == .cannotEdit(ClientRegistrar.tooLargeForFileEdit(.claudeCode)))
        guard case .failed = await r.connect(.claudeCode) else { Issue.record("expected failure"); return }
        #expect(read(file) == big)
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.path) == [".claude.json"])
    }

    @Test func claudeCodeFallsBackToFile() async throws {
        let home = try makeTempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let json = MCPClient.claudeCode.configURL(home: home)
        try write(#"{"numStartups":3}"#, to: json)
        let runner = FakeRunner()
        let r = makeRegistrar(home: home, runner: runner)
        let outcome = await r.connect(.claudeCode)
        guard case .done(let backup) = outcome, let backup else { Issue.record("expected backup, got \(outcome)"); return }
        #expect(read(backup) == #"{"numStartups":3}"#)
        #expect(runner.calls.isEmpty)
        let parsed = try OrderedJSON.parse(Data(read(json).utf8))
        let entry: OrderedJSON = .object([("type", .string("stdio")), ("command", .string(serverPath)), ("args", .array([])), ("env", .object([]))])
        #expect(parsed == .object([("numStartups", .number("3")), ("mcpServers", .object([("remora", entry)]))]))
        #expect(await r.status(.claudeCode) == .connected)
    }

    @Test func codexUsesCLIAndPassesPathAsOneArgument() async throws {
        let home = try makeTempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let weird = "/Users/a b/\"q\" ';rm -rf/remora-mcp"
        let cfg = MCPClient.codex.configURL(home: home)
        let runner = FakeRunner { args in
            if args.starts(with: ["mcp", "add"]) {
                try? FileManager.default.createDirectory(at: cfg.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data(("[mcp_servers.remora]\ncommand = \"" + weird.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"\n").utf8).write(to: cfg)
            }
            return CommandResult(status: 0, stdout: "", stderr: "")
        }
        let r = makeRegistrar(home: home, serverPath: weird, runner: runner, cliPaths: ["/usr/local/bin/codex"])
        #expect(await r.connect(.codex) == .done(backup: nil))
        #expect(runner.calls == [["mcp", "add", "remora", "--", weird]])
    }

    @Test func codexCLIFailureSurfaces() async throws {
        let home = try makeTempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let runner = FakeRunner { _ in CommandResult(status: 1, stdout: "", stderr: "boom") }
        let r = makeRegistrar(home: home, runner: runner, cliPaths: ["/usr/local/bin/codex"])
        guard case .failed(let message) = await r.connect(.codex) else { Issue.record("expected failure"); return }
        #expect(message.contains("boom"))
    }

    @Test func codexFileFallbackAppendsAndDisconnectRestores() async throws {
        let home = try makeTempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let cfg = MCPClient.codex.configURL(home: home)
        let original = "model = \"o\"\n\n[mcp_servers.x]\ncommand = \"/x\"\n"
        try write(original, to: cfg)
        let r = makeRegistrar(home: home)
        guard case .done(let backup) = await r.connect(.codex), let backup else { Issue.record("expected backup"); return }
        #expect(read(backup) == original)
        #expect(read(cfg).hasPrefix(original))
        #expect(try CodexTOML.serverCommand(in: read(cfg)) == serverPath)
        #expect(await r.status(.codex) == .connected)
        guard case .done = await r.disconnect(.codex) else { Issue.record("disconnect failed"); return }
        #expect(read(cfg) == original)
        #expect(await r.status(.codex) == .notConnected)
    }

    @Test func codexFileFallbackReplacesElsewhereEntry() async throws {
        let home = try makeTempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let cfg = MCPClient.codex.configURL(home: home)
        try write("[mcp_servers.remora]\ncommand = \"/Old\"\nargs = []\n\n[tui]\nx = 1\n", to: cfg)
        let r = makeRegistrar(home: home)
        #expect(await r.status(.codex) == .connectedElsewhere(command: "/Old"))
        guard case .done = await r.connect(.codex) else { Issue.record("connect failed"); return }
        #expect(await r.status(.codex) == .connected)
        #expect(read(cfg).contains("[tui]\nx = 1\n"))
        #expect(!read(cfg).contains("/Old"))
    }

    @Test func connectedElsewhereDetected() async throws {
        let home = try makeTempHome(); defer { try? FileManager.default.removeItem(at: home) }
        try write(#"{"mcpServers":{"remora":{"command":"/Old/remora-mcp"}}}"#, to: MCPClient.cursor.configURL(home: home))
        let r = makeRegistrar(home: home)
        #expect(await r.status(.cursor) == .connectedElsewhere(command: "/Old/remora-mcp"))
    }

    @Test func connectWhenAlreadyConnectedDoesNotTouchTheFile() async throws {
        let home = try makeTempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let file = MCPClient.cursor.configURL(home: home)
        let src = "{ \"mcpServers\": { \"remora\": { \"command\": \"\(serverPath)\" } } }"
        try write(src, to: file)
        let r = makeRegistrar(home: home)
        #expect(await r.connect(.cursor) == .done(backup: nil))
        #expect(read(file) == src)
    }

    @Test func cannotEditReportsReason() async throws {
        let home = try makeTempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let file = MCPClient.cursor.configURL(home: home)
        let src = "{\n  // my servers\n  \"mcpServers\": {}\n}\n"
        try write(src, to: file)
        let r = makeRegistrar(home: home)
        guard case .cannotEdit(let message) = await r.status(.cursor) else { Issue.record("expected cannotEdit"); return }
        #expect(!message.isEmpty)
        #expect(message == ConfigError.unparseable(line: 2, column: 3, reason: "").userMessage)
        guard case .failed = await r.connect(.cursor) else { Issue.record("expected failure"); return }
        guard case .failed = await r.disconnect(.cursor) else { Issue.record("expected failure"); return }
        #expect(read(file) == src)
        #expect(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path) == ["mcp.json"])
    }

    @Test func unsupportedCodexTOMLIsNotEdited() async throws {
        let home = try makeTempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let cfg = MCPClient.codex.configURL(home: home)
        let src = "mcp_servers = { x = { command = \"/x\" } }\n"
        try write(src, to: cfg)
        let r = makeRegistrar(home: home)
        guard case .cannotEdit = await r.status(.codex) else { Issue.record("expected cannotEdit"); return }
        guard case .failed = await r.connect(.codex) else { Issue.record("expected failure"); return }
        #expect(read(cfg) == src)
    }

    @Test func disconnectRemovesOnlyOurEntry() async throws {
        let home = try makeTempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let file = MCPClient.claudeDesktop.configURL(home: home)
        try write(#"{"theme":"dark","mcpServers":{"a":{"command":"1"},"remora":{"command":"\#(serverPath)"}}}"#, to: file)
        let r = makeRegistrar(home: home, installedApps: [desktopID])
        guard case .done(let backup) = await r.disconnect(.claudeDesktop), backup != nil else { Issue.record("expected backup"); return }
        #expect(try OrderedJSON.parse(Data(read(file).utf8)) == (try OrderedJSON.parse(Data(#"{"theme":"dark","mcpServers":{"a":{"command":"1"}}}"#.utf8))))
        #expect(await r.status(.claudeDesktop) == .notConnected)
        #expect(await r.disconnect(.claudeDesktop) == .done(backup: nil))
    }

    @Test func disconnectViaCLIRunsRemove() async throws {
        let home = try makeTempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let cli = FakeClaudeCLI(registered: serverPath)
        let r = makeRegistrar(home: home, runner: cli.runner, cliPaths: ["/opt/homebrew/bin/claude"])
        #expect(await r.disconnect(.claudeCode) == .done(backup: nil))
        #expect(cli.runner.calls.filter { $0[1] != "get" } == [["mcp", "remove", "--scope", "user", "remora"]])
    }

    @Test func disconnectDoesNotReportSuccessWhenVerificationFails() async throws {
        let home = try makeTempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let gets = Counter()
        let runner = FakeRunner { args in
            if args[1] == "get" {
                if gets.next() == 1 {
                    return CommandResult(status: 0, stdout: "Scope: User config\nCommand: /Applications/Remora.app/Contents/MacOS/remora-mcp\n", stderr: "")
                }
                return CommandResult(status: -1, stdout: "", stderr: "The command timed out.")
            }
            return CommandResult(status: 0, stdout: "", stderr: "")
        }
        let registrar = makeRegistrar(home: home, runner: runner, cliPaths: ["/opt/homebrew/bin/claude"])
        guard case .failed = await registrar.disconnect(.claudeCode) else {
            Issue.record("An unreadable status cannot verify disconnection")
            return
        }
        #expect(runner.calls.filter { $0[1] == "get" }.count == 2)
    }

    @Test func codexCLIDisconnectRunsRemove() async throws {
        let home = try makeTempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let cfg = MCPClient.codex.configURL(home: home)
        try write("[mcp_servers.remora]\ncommand = \"\(serverPath)\"\nargs = []\n", to: cfg)
        let runner = FakeRunner { args in
            if args == ["mcp", "remove", "remora"] { try? Data("model = \"o\"\n".utf8).write(to: cfg) }
            return CommandResult(status: 0, stdout: "", stderr: "")
        }
        let r = makeRegistrar(home: home, runner: runner, cliPaths: ["/usr/local/bin/codex"])
        #expect(await r.disconnect(.codex) == .done(backup: nil))
        #expect(runner.calls == [["mcp", "remove", "remora"]])
        #expect(await r.status(.codex) == .notConnected)
    }

    @Test func danglingSymlinkConfigIsBenign() async throws {
        let home = try makeTempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let cur = home.appendingPathComponent(".cursor")
        try FileManager.default.createDirectory(at: cur, withIntermediateDirectories: true)
        let link = cur.appendingPathComponent("mcp.json")
        let target = home.appendingPathComponent("gone/mcp.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let r = makeRegistrar(home: home)
        #expect(await r.status(.cursor) == .notConnected)
        let outcome = await r.connect(.cursor)
        // Whatever happens, the link is still a link, nothing leaks outside, and no temp files stay.
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == target.path)
        let names = try FileManager.default.contentsOfDirectory(atPath: cur.path)
        #expect(names == ["mcp.json"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.path).sorted() == [".cursor"])
        // The parent of the dangling target doesn't exist, so the write is refused rather than created.
        guard case .failed = outcome else { Issue.record("expected a refusal, got \(outcome)"); return }
    }

    @Test func fileChangedBetweenReadAndWriteIsRefused() throws {
        // The registrar delegates this to SafeFileWriter; verify the end-to-end guard with real files.
        let home = try makeTempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let file = MCPClient.cursor.configURL(home: home)
        try write(#"{"a":1}"#, to: file)
        let w = SafeFileWriter(now: steppingClock())
        let (data, resolved) = try w.read(file)
        let newData = try JSONConfigEditor.upsertServer(in: data, entry: .object([("command", .string("/p"))]))
        try Data(#"{"a":2}"#.utf8).write(to: file)
        #expect(throws: ConfigError.changedOnDisk) { try w.write(newData, to: resolved, expectedOriginal: data) }
        #expect(read(file) == #"{"a":2}"#)
    }
}

@Suite struct ExecutableLocatorTests {
    @Test func searchesInPinnedOrder() async {
        let home = URL(fileURLWithPath: "/H", isDirectory: true)
        let all: Set<String> = ["/H/.local/bin/claude", "/H/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        let l = ExecutableLocator(home: home, fileExists: { all.contains($0) }, loginShellLookup: nil)
        #expect(await l.find("claude")?.path == "/H/.local/bin/claude")
        let l2 = ExecutableLocator(home: home, fileExists: { $0 == "/H/.claude/local/claude" || $0 == "/opt/homebrew/bin/claude" }, loginShellLookup: nil)
        #expect(await l2.find("claude")?.path == "/H/.claude/local/claude")
        let l3 = ExecutableLocator(home: home, fileExists: { $0 == "/H/.claude/local/codex" || $0 == "/usr/local/bin/codex" }, loginShellLookup: nil)
        #expect(await l3.find("codex")?.path == "/usr/local/bin/codex")
        for dir in ["/H/.npm-global/bin", "/H/.bun/bin", "/H/.volta/bin"] {
            let l4 = ExecutableLocator(home: home, fileExists: { $0 == dir + "/codex" }, loginShellLookup: nil)
            #expect(await l4.find("codex")?.path == dir + "/codex")
        }
    }

    @Test func fallsBackToLoginShellAndValidatesAnswer() async {
        let home = URL(fileURLWithPath: "/H", isDirectory: true)
        let ok = ExecutableLocator(home: home, fileExists: { $0 == "/weird/claude" }, loginShellLookup: { _ in "motd noise\n/weird/claude\n" })
        #expect(await ok.find("claude")?.path == "/weird/claude")
        let missing = ExecutableLocator(home: home, fileExists: { _ in false }, loginShellLookup: { _ in "/nope/claude" })
        #expect(await missing.find("claude") == nil)
        let relative = ExecutableLocator(home: home, fileExists: { $0 == "claude" }, loginShellLookup: { _ in "claude" })
        #expect(await relative.find("zzz") == nil)
    }

    @Test func rejectsUnsafeNames() async {
        let home = URL(fileURLWithPath: "/H", isDirectory: true)
        let l = ExecutableLocator(home: home, fileExists: { _ in true }, loginShellLookup: { _ in "/x/y" })
        #expect(await l.find("claude; rm -rf /") == nil)
        #expect(await l.find("../claude") == nil)
        #expect(await l.find("") == nil)
    }
}
