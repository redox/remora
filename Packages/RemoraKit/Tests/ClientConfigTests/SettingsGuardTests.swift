import Foundation
import Testing
@testable import ClientConfig

/// Plan 5 Task 12 carries from the Task 9 review: the Settings › MCP guards.
@Suite struct SettingsGuardTests {
    @Test func hugeClaudeJSONWithoutCLIAsksForTheCLI() async throws {
        let home = try makeTempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let file = MCPClient.claudeCode.configURL(home: home)
        let big = "{\"projects\":\"" + String(repeating: "x", count: SafeFileWriter.maxFileSize + 1) + "\"}"
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(big.utf8).write(to: file)
        let r = makeRegistrar(home: home)
        #expect(await r.status(.claudeCode) == .cannotEdit(ClientRegistrar.tooLargeForFileEdit(.claudeCode)))
        #expect(await r.connect(.claudeCode) == .failed(ClientRegistrar.tooLargeForFileEdit(.claudeCode)))
        #expect(ClientRegistrar.tooLargeForFileEdit(.claudeCode) == "Too large to edit; install the claude CLI.")
        #expect(read(file) == big)
    }

    @Test func hugeClaudeJSONWithCLIStaysConnectable() async throws {
        let home = try makeTempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let file = MCPClient.claudeCode.configURL(home: home)
        let big = "{\"projects\":\"" + String(repeating: "x", count: SafeFileWriter.maxFileSize + 1) + "\"}"
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(big.utf8).write(to: file)
        let cli = FakeClaudeCLI()
        let r = makeRegistrar(home: home, runner: cli.runner, cliPaths: ["/opt/homebrew/bin/claude"])
        #expect(await r.status(.claudeCode) == .notConnected)
    }

    @Test func translocatedOrMissingServerRefusesConnect() {
        let ok = "/Applications/Remora.app"
        #expect(ServerLocation.refusal(bundlePath: ok, toolIsExecutable: true) == nil)
        #expect(ServerLocation.refusal(bundlePath: "/Users/me/dev/remora/build/Build/Products/Debug/Remora.app",
                                       toolIsExecutable: true) == nil)
        let translocated = "/private/var/folders/ab/T/AppTranslocation/0A1B/d/Remora.app"
        #expect(ServerLocation.refusal(bundlePath: translocated, toolIsExecutable: true) == ServerLocation.translocatedMessage)
        #expect(ServerLocation.refusal(bundlePath: ok, toolIsExecutable: false) == ServerLocation.missingToolMessage)
        // Case-insensitive, like the file system.
        #expect(ServerLocation.refusal(bundlePath: "/private/var/folders/x/apptranslocation/y/Remora.app",
                                       toolIsExecutable: true) == ServerLocation.translocatedMessage)
    }

    /// Plan 5 × Plan 6: one guard. Not installed refuses first (with the app's caption), then
    /// translocation and a missing tool; an installed copy with the tool may connect.
    @Test func notInstalledOrMissingToolRefusesConnect() {
        let caption = "Move Remora to Applications first."
        let ok = "/Applications/Remora.app"
        #expect(ServerLocation.refusal(isInstalled: true, notInstalledMessage: caption,
                                       bundlePath: ok, toolIsExecutable: true) == nil)
        #expect(ServerLocation.refusal(isInstalled: false, notInstalledMessage: caption,
                                       bundlePath: "/Volumes/Remora/Remora.app", toolIsExecutable: true) == caption)
        #expect(ServerLocation.refusal(isInstalled: false, notInstalledMessage: caption,
                                       bundlePath: ok, toolIsExecutable: false) == caption)
        #expect(ServerLocation.refusal(isInstalled: true, notInstalledMessage: caption,
                                       bundlePath: ok, toolIsExecutable: false) == ServerLocation.missingToolMessage)
    }

    @Test func serverPathIsResolvedThroughSymlinks() throws {
        let dir = try makeTempHome(); defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("Real.app", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = dir.appendingPathComponent("Link.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let path = ServerLocation.toolPath(bundleURL: link)
        #expect(path.hasSuffix("/Real.app/Contents/MacOS/remora-mcp"))
        #expect(!path.contains("Link.app"))
    }
}
