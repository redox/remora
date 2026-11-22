import Foundation
@testable import ClientConfig

func makeTempHome() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}

/// A clock that moves one second per call, starting at a fixed date.
func steppingClock() -> @Sendable () -> Date {
    let c = Counter()
    return { Date(timeIntervalSince1970: 1_700_000_000 + Double(c.next())) }
}

final class FakeRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []
    private var _executables: [String] = []
    private let handler: @Sendable ([String]) -> CommandResult

    init(_ handler: @escaping @Sendable ([String]) -> CommandResult = { _ in CommandResult(status: 0, stdout: "", stderr: "") }) {
        self.handler = handler
    }

    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return _calls }
    var executables: [String] { lock.lock(); defer { lock.unlock() }; return _executables }

    private func record(_ arguments: [String], _ executable: String) {
        lock.withLock { _calls.append(arguments); _executables.append(executable) }
    }

    func run(_ executable: URL, _ arguments: [String], timeout: Duration) async -> CommandResult {
        record(arguments, executable.path)
        return handler(arguments)
    }
}

func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "<missing>" }

func makeRegistrar(
    home: URL,
    serverPath: String = "/Apps/Remora.app/Contents/MacOS/remora-mcp",
    runner: any CommandRunning = FakeRunner(),
    cliPaths: Set<String> = [],
    installedApps: Set<String> = []
) -> ClientRegistrar {
    ClientRegistrar(
        home: home,
        serverPath: serverPath,
        runner: runner,
        locator: ExecutableLocator(home: home, fileExists: { cliPaths.contains($0) }, loginShellLookup: nil),
        appInstalled: { installedApps.contains($0) },
        writer: SafeFileWriter(now: steppingClock())
    )
}

/// A stateful stand-in for `claude mcp get/add/remove`.
final class FakeClaudeCLI: @unchecked Sendable {
    private let lock = NSLock()
    private var registered: String?
    private let addIsNoOp: Bool
    private(set) var runner: FakeRunner!

    init(registered: String? = nil, addIsNoOp: Bool = false) {
        self.registered = registered
        self.addIsNoOp = addIsNoOp
        self.runner = FakeRunner { [unowned self] args in self.handle(args) }
    }

    private func handle(_ args: [String]) -> CommandResult {
        lock.withLock {
            switch args[1] {
            case "get":
                guard let registered else { return CommandResult(status: 1, stdout: "", stderr: "No MCP server found with name: remora") }
                return CommandResult(status: 0, stdout: "remora:\n  Scope: User config\n  Status: Connected\n  Type: stdio\n  Command: \(registered)\n  Args:\n", stderr: "")
            case "add":
                if !addIsNoOp { registered = args.last }
            case "remove":
                registered = nil
            default: break
            }
            return CommandResult(status: 0, stdout: "", stderr: "")
        }
    }
}
