import Foundation

public struct CommandResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol CommandRunning: Sendable {
    /// Runs `executable` with `arguments` (no shell). Status −1 means it could not run or timed out.
    func run(_ executable: URL, _ arguments: [String], timeout: Duration) async -> CommandResult
}

/// Runs a real process. Tests never instantiate this.
public struct ProcessRunner: CommandRunning {
    private let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    public func run(_ executable: URL, _ arguments: [String], timeout: Duration) async -> CommandResult {
        let job = Job(executable: executable, arguments: arguments, home: home)
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        return await job.run(timeoutSeconds: seconds)
    }

    private final class Job: @unchecked Sendable {
        private let process = Process()
        private let outPipe = Pipe()
        private let errPipe = Pipe()
        private let lock = NSLock()
        private var out = Data()
        private var err = Data()
        private var timedOut = false
        private var finished = false
        private static let cap = 64 * 1024

        init(executable: URL, arguments: [String], home: URL) {
            process.executableURL = executable
            process.arguments = arguments
            var env = ProcessInfo.processInfo.environment
            env["HOME"] = home.path
            // A GUI app inherits a minimal PATH; the CLIs are often node scripts that need `node`.
            let extra = ["/opt/homebrew/bin", "/usr/local/bin", home.appendingPathComponent(".local/bin").path,
                         home.appendingPathComponent(".volta/bin").path, home.appendingPathComponent(".bun/bin").path,
                         home.appendingPathComponent(".npm-global/bin").path]
            env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
            process.environment = env
            process.standardInput = FileHandle(forReadingAtPath: "/dev/null") ?? FileHandle.nullDevice
            process.standardOutput = outPipe
            process.standardError = errPipe
        }

        private var continuation: CheckedContinuation<CommandResult, Never>?
        private var terminated = false
        private var eofOut = false
        private var eofErr = false
        private var done = false
        /// How long we keep reading after the process exits. A grandchild that inherited our
        /// pipes must not be able to hang the caller.
        private static let drainGrace = 0.5

        func run(timeoutSeconds: Double) async -> CommandResult {
            await withCheckedContinuation { (continuation: CheckedContinuation<CommandResult, Never>) in
                lock.withLock { self.continuation = continuation }
                outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        handle.readabilityHandler = nil
                        self?.markEOF(error: false)
                    } else {
                        self?.append(chunk, toError: false)
                    }
                }
                errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        handle.readabilityHandler = nil
                        self?.markEOF(error: true)
                    } else {
                        self?.append(chunk, toError: true)
                    }
                }
                process.terminationHandler = { [weak self] _ in
                    guard let self else { return }
                    self.lock.withLock { self.terminated = true }
                    self.finishIfDrained()
                    DispatchQueue.global().asyncAfter(deadline: .now() + Self.drainGrace) { [weak self] in
                        self?.finish()
                    }
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    lock.withLock { terminated = true }
                    finish(override: CommandResult(status: -1, stdout: "", stderr: "The command could not be started."))
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
                    self?.killIfRunning()
                }
            }
        }

        private func markEOF(error: Bool) {
            lock.withLock { if error { eofErr = true } else { eofOut = true } }
            finishIfDrained()
        }

        private func finishIfDrained() {
            let ready = lock.withLock { terminated && eofOut && eofErr }
            if ready { finish() }
        }

        /// Idempotent: stops reading, closes our ends of the pipes and resumes the caller once.
        private func finish(override: CommandResult? = nil) {
            let pending: CheckedContinuation<CommandResult, Never>? = lock.withLock {
                if done { return nil }
                done = true
                defer { continuation = nil }
                return continuation
            }
            guard let pending else { return }
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            try? outPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForReading.close()
            pending.resume(returning: override ?? result())
        }

        private func append(_ chunk: Data, toError: Bool) {
            lock.lock(); defer { lock.unlock() }
            if toError {
                if err.count < Self.cap { err.append(chunk.prefix(Self.cap - err.count)) }
            } else if out.count < Self.cap {
                out.append(chunk.prefix(Self.cap - out.count))
            }
        }

        private func killIfRunning() {
            guard process.isRunning else { return }
            lock.lock(); timedOut = true; lock.unlock()
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
                if self?.process.isRunning == true { kill(pid, SIGKILL) }
            }
        }

        private func result() -> CommandResult {
            lock.lock(); defer { lock.unlock() }
            if timedOut { return CommandResult(status: -1, stdout: "", stderr: "The command timed out.") }
            return CommandResult(
                status: process.terminationStatus,
                stdout: String(decoding: out, as: UTF8.self),
                stderr: String(decoding: err, as: UTF8.self)
            )
        }
    }
}
