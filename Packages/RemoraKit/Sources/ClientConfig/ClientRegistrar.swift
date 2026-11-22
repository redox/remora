import Foundation

public enum ClientStatus: Sendable, Equatable {
    case notInstalled
    case notConnected
    case connected
    case connectedElsewhere(command: String)
    case cannotEdit(String)
}

public enum ConnectOutcome: Sendable, Equatable {
    case done(backup: URL?)
    case failed(String)
}

/// Registers (and unregisters) Remora's MCP server with a client. Prefers the client's own CLI;
/// otherwise edits the client's config file through `SafeFileWriter`.
public struct ClientRegistrar: Sendable {
    private let home: URL
    private let serverPath: String
    private let runner: any CommandRunning
    private let locator: ExecutableLocator
    private let appInstalled: @Sendable (String) -> Bool
    private let writer: SafeFileWriter

    private static let cliTimeout: Duration = .seconds(15)

    public init(
        home: URL,
        serverPath: String,
        runner: any CommandRunning,
        locator: ExecutableLocator,
        appInstalled: @escaping @Sendable (String) -> Bool,
        writer: SafeFileWriter
    ) {
        self.home = home
        self.serverPath = serverPath
        self.runner = runner
        self.locator = locator
        self.appInstalled = appInstalled
        self.writer = writer
    }

    // MARK: - Status

    public func status(_ c: MCPClient) async -> ClientStatus {
        guard await isInstalled(c) else { return .notInstalled }
        do {
            let cli = await cliURL(c)
            let state = try await currentState(c, cli: cli, maxSize: SafeFileWriter.maxReadSize)
            guard state.present else {
                // Readable for status but over the write cap: Connect could only fail.
                if cli == nil, let data = state.data, data.count > SafeFileWriter.maxFileSize {
                    return .cannotEdit(Self.tooLargeForFileEdit(c))
                }
                return .notConnected
            }
            return state.command == serverPath ? .connected : .connectedElsewhere(command: state.command)
        } catch {
            return .cannotEdit(error.userMessage)
        }
    }

    // MARK: - Connect / disconnect

    public func connect(_ c: MCPClient) async -> ConnectOutcome {
        guard await isInstalled(c) else { return .failed("\(c.displayName) doesn't seem to be installed.") }
        let cli = await cliURL(c)
        let state: Snapshot
        do { state = try await currentState(c, cli: cli, maxSize: cli == nil ? SafeFileWriter.maxFileSize : SafeFileWriter.maxReadSize) } catch { return .failed(message(error, c, cli: cli)) }
        if state.present, state.command == serverPath { return .done(backup: nil) }

        if let cli {
            if state.present {
                let removal = await runner.run(cli, removeArguments(c), timeout: Self.cliTimeout)
                if removal.status != 0 { return .failed(Self.describe(removal)) }
            }
            let addition = await runner.run(cli, addArguments(c), timeout: Self.cliTimeout)
            if addition.status != 0 { return .failed(Self.describe(addition)) }
            guard await status(c) == .connected else {
                return .failed("\(c.displayName) accepted the command, but Remora isn't listed there yet.")
            }
            return .done(backup: nil)
        }

        do {
            let backup = try editFile(c, state: state, add: true)
            guard await status(c) == .connected else { return .failed("The change could not be verified.") }
            return .done(backup: backup)
        } catch {
            return .failed(error.userMessage)
        }
    }

    public func disconnect(_ c: MCPClient) async -> ConnectOutcome {
        guard await isInstalled(c) else { return .done(backup: nil) }
        let cli = await cliURL(c)
        let state: Snapshot
        do { state = try await currentState(c, cli: cli, maxSize: cli == nil ? SafeFileWriter.maxFileSize : SafeFileWriter.maxReadSize) } catch { return .failed(message(error, c, cli: cli)) }
        guard state.present else { return .done(backup: nil) }

        if let cli {
            let removal = await runner.run(cli, removeArguments(c), timeout: Self.cliTimeout)
            if removal.status != 0 { return .failed(Self.describe(removal)) }
            switch await status(c) {
            case .notConnected: return .done(backup: nil)
            case .connected, .connectedElsewhere: return .failed("\(c.displayName) still lists Remora.")
            case .cannotEdit(let reason): return .failed(reason)
            case .notInstalled: return .failed("The change could not be verified.")
            }
        }

        do {
            return .done(backup: try editFile(c, state: state, add: false))
        } catch {
            return .failed(error.userMessage)
        }
    }

    /// A config file over the write cap, with no CLI to make the change instead.
    public static func tooLargeForFileEdit(_ c: MCPClient) -> String {
        switch c {
        case .claudeCode: "Too large to edit; install the claude CLI."
        case .codex: "Too large to edit; install the codex CLI."
        case .claudeDesktop, .cursor: ConfigError.tooLarge.userMessage
        }
    }

    private func message(_ error: ConfigError, _ c: MCPClient, cli: URL?) -> String {
        error == .tooLarge && cli == nil ? Self.tooLargeForFileEdit(c) : error.userMessage
    }

    // MARK: - Internals

    private struct Snapshot {
        var present: Bool
        var command: String
        var data: Data?
        var resolved: URL
    }

    private func isInstalled(_ c: MCPClient) async -> Bool {
        if c.appBundleIDs.contains(where: appInstalled) { return true }
        let file = c.configURL(home: home)
        switch c {
        case .claudeCode:
            if FileManager.default.fileExists(atPath: file.path) { return true }
        default:
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path, isDirectory: &isDirectory), isDirectory.boolValue {
                return true
            }
        }
        if cliName(c) != nil { return await cliURL(c) != nil }
        return false
    }

    private func cliName(_ c: MCPClient) -> String? {
        switch c {
        case .claudeCode: "claude"
        case .codex: "codex"
        case .claudeDesktop, .cursor: nil
        }
    }

    private func cliURL(_ c: MCPClient) async -> URL? {
        guard let name = cliName(c) else { return nil }
        return await locator.find(name)
    }

    private func addArguments(_ c: MCPClient) -> [String] {
        switch c {
        case .claudeCode: ["mcp", "add", "--scope", "user", "remora", serverPath]
        default: ["mcp", "add", "remora", "--", serverPath]
        }
    }

    private func removeArguments(_ c: MCPClient) -> [String] {
        switch c {
        case .claudeCode: ["mcp", "remove", "--scope", "user", "remora"]
        default: ["mcp", "remove", "remora"]
        }
    }

    /// Claude Code's file is huge and owned by the CLI, so with the CLI present we ask it
    /// (`claude mcp get`) instead of parsing the file.
    private func currentState(_ c: MCPClient, cli: URL?, maxSize: Int) async throws(ConfigError) -> Snapshot {
        guard c == .claudeCode, let cli else { return try snapshot(c, maxSize: maxSize) }
        let result = await runner.run(cli, ["mcp", "get", "remora"], timeout: Self.cliTimeout)
        let resolved = c.configURL(home: home)
        if result.status == 0 {
            let lines = result.stdout.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let scope = lines.first { $0.hasPrefix("Scope:") }
                .map { String($0.dropFirst("Scope:".count)).trimmingCharacters(in: .whitespaces) } ?? ""
            // `get` can resolve a project entry, but our mutations always use --scope user.
            // Refuse an unknown or different scope instead of changing an unrelated entry.
            guard scope == "User config" || scope.hasPrefix("User config (") else {
                throw ConfigError.commandFailed(status: 0, message:
                    "Remora couldn't verify a user-level MCP entry. Manage this entry in Claude Code.")
            }
            let line = lines.first { $0.hasPrefix("Command:") }
            let command = line.map { String($0.dropFirst("Command:".count)).trimmingCharacters(in: .whitespaces) } ?? ""
            return Snapshot(present: true, command: command, data: nil, resolved: resolved)
        }
        let text = (result.stderr + result.stdout).lowercased()
        if result.status > 0, text.contains("no mcp server found") {
            return Snapshot(present: false, command: "", data: nil, resolved: resolved)
        }
        throw ConfigError.commandFailed(status: result.status, message: Self.describe(result))
    }

    private func snapshot(_ c: MCPClient, maxSize: Int) throws(ConfigError) -> Snapshot {
        let (data, resolved) = try writer.read(c.configURL(home: home), maxSize: maxSize)
        if c == .codex {
            var command: String?
            if let data {
                guard let text = String(data: data, encoding: .utf8) else { throw ConfigError.unsupportedTOML("not UTF-8") }
                command = try CodexTOML.serverCommand(in: text)
            }
            return Snapshot(present: command != nil, command: command ?? "", data: data, resolved: resolved)
        }
        guard let entry = try JSONConfigEditor.server(in: data) else {
            return Snapshot(present: false, command: "", data: data, resolved: resolved)
        }
        let command = entry.objectPairs?.first(where: { $0.0 == "command" })?.1.stringValue ?? ""
        return Snapshot(present: true, command: command, data: data, resolved: resolved)
    }

    /// Adds or removes our entry in the config file. Returns the backup, if one was made.
    private func editFile(_ c: MCPClient, state: Snapshot, add: Bool) throws(ConfigError) -> URL? {
        let newData: Data
        if c == .codex {
            var text = ""
            if let data = state.data {
                guard let decoded = String(data: data, encoding: .utf8) else { throw ConfigError.unsupportedTOML("not UTF-8") }
                text = decoded
            }
            if state.present { text = try CodexTOML.removeServer(from: text) }
            if add { text = try CodexTOML.appendServer(to: text, command: serverPath) }
            newData = Data(text.utf8)
        } else if add {
            newData = try JSONConfigEditor.upsertServer(in: state.data, entry: jsonEntry(c))
        } else if let data = state.data {
            newData = try JSONConfigEditor.removeServer(in: data)
        } else {
            return nil
        }
        if newData == state.data { return nil }  // nothing to change: never write
        try ensureParentDirectory(c, of: state.resolved)
        return try writer.write(newData, to: state.resolved, expectedOriginal: state.data)
    }

    private func jsonEntry(_ c: MCPClient) -> OrderedJSON {
        if c == .claudeCode {
            return .object([("type", .string("stdio")), ("command", .string(serverPath)), ("args", .array([])), ("env", .object([]))])
        }
        return .object([("command", .string(serverPath)), ("args", .array([]))])
    }

    /// Only Cursor's `~/.cursor` and Claude Desktop's `Claude` folder are ever created, and only
    /// because the app itself is installed.
    private func ensureParentDirectory(_ c: MCPClient, of resolved: URL) throws(ConfigError) {
        let directory = resolved.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: directory.path) { return }
        guard c == .cursor || c == .claudeDesktop, c.appBundleIDs.contains(where: appInstalled) else {
            throw ConfigError.io("The settings folder doesn't exist.")
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ConfigError.io("Couldn't create the settings folder.")
        }
    }

    private static func describe(_ result: CommandResult) -> String {
        if result.status == -1 { return result.stderr.isEmpty ? "The command did not finish." : result.stderr }
        let text = (result.stderr.isEmpty ? result.stdout : result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "The command failed (exit \(result.status))." }
        return String(text.prefix(300))
    }
}
