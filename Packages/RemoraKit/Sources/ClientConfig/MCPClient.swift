import Foundation

/// An MCP client Remora can register its server with.
public enum MCPClient: String, Sendable, CaseIterable {
    case claudeCode, claudeDesktop, cursor, codex

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .claudeDesktop: "Claude Desktop"
        case .cursor: "Cursor"
        case .codex: "Codex"
        }
    }

    public var appBundleIDs: [String] {
        switch self {
        case .claudeDesktop: ["com.anthropic.claudefordesktop"]
        case .cursor: ["com.todesktop.230313mzl4w4u92"]
        case .claudeCode, .codex: []
        }
    }

    /// The file Remora reads (and, without a CLI, edits) for this client.
    public func configURL(home: URL) -> URL {
        switch self {
        case .claudeCode:
            home.appendingPathComponent(".claude.json")
        case .claudeDesktop:
            home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        case .cursor:
            home.appendingPathComponent(".cursor/mcp.json")
        case .codex:
            home.appendingPathComponent(".codex/config.toml")
        }
    }
}

public enum ConfigError: Error, Sendable, Equatable {
    case unparseable(line: Int, column: Int, reason: String)
    case unexpectedShape(String)
    case notRoundTrippable
    case changedOnDisk
    case tooLarge
    case unsupportedTOML(String)
    case io(String)
    case commandFailed(status: Int32, message: String)

    /// Short, content-free text that is safe to show in the UI.
    public var userMessage: String {
        switch self {
        case .unparseable:
            "Its settings file has comments or a format Remora can't safely change."
        case .unexpectedShape:
            "Its settings file has an unexpected layout, so Remora left it alone."
        case .notRoundTrippable:
            "Remora can't rewrite its settings file without altering other settings, so it left it alone."
        case .changedOnDisk:
            "Its settings file changed while Remora was working. Nothing was written; try again."
        case .tooLarge:
            "Its settings file is unusually large, so Remora left it alone."
        case .unsupportedTOML:
            "Its settings file uses a layout Remora can't safely change."
        case .io:
            "Remora couldn't read or write its settings file."
        case .commandFailed(_, let message):
            message.isEmpty ? "Its command line tool reported an error." : message
        }
    }
}
