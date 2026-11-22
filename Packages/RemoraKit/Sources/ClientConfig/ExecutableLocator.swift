import Foundation

/// Finds a command line tool without trusting the (minimal) PATH of a GUI app.
public struct ExecutableLocator: Sendable {
    private let home: URL
    private let fileExists: @Sendable (String) -> Bool
    private let loginShellLookup: (@Sendable (String) async -> String?)?

    public init(home: URL, fileExists: @escaping @Sendable (String) -> Bool, loginShellLookup: (@Sendable (String) async -> String?)?) {
        self.home = home
        self.fileExists = fileExists
        self.loginShellLookup = loginShellLookup
    }

    public func find(_ name: String) async -> URL? {
        // The name ends up in a shell command for the login-shell lookup: keep it boring.
        guard !name.isEmpty, !name.hasPrefix("."), name.unicodeScalars.allSatisfy({ Self.allowed.contains($0) }) else { return nil }
        var directories = [home.appendingPathComponent(".local/bin").path]
        if name == "claude" { directories.append(home.appendingPathComponent(".claude/local").path) }
        directories += ["/opt/homebrew/bin", "/usr/local/bin"]
        directories += [".npm-global/bin", ".bun/bin", ".volta/bin"].map { home.appendingPathComponent($0).path }
        for directory in directories {
            let path = directory + "/" + name
            if fileExists(path) { return URL(fileURLWithPath: path) }
        }
        guard let loginShellLookup, let answer = await loginShellLookup(name) else { return nil }
        // Login shells may print banners; the path is the last non-empty line.
        guard let line = answer.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }).last(where: { !$0.isEmpty }),
              line.hasPrefix("/"), fileExists(line) else { return nil }
        return URL(fileURLWithPath: line)
    }

    private static let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
}
