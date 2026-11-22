import AppKit
import os
import SwiftUI

/// Exports Remora's unified-log entries (subsystem `dev.remora`) to a file. The log holds events,
/// counts and error codes only (never content), so the export does too.
///
/// `ProcessRunner` keeps at most 64 KB of output, so the export streams `log show` straight into
/// the file instead.
enum LogExport {
    static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Remora", isDirectory: true)
    static let timeout: TimeInterval = 120
    static let arguments = ["show", "--info", "--predicate", "subsystem == \"dev.remora\"", "--last", "24h", "--style", "compact"]

    enum Outcome: Sendable {
        case done(URL)
        case failed(String)
    }

    static func fileName(at date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "remora-\(f.string(from: date)).log"
    }

    static func ensureFolder() throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Runs `/usr/bin/log show …` into a new file in the logs folder, off the main actor. No thread
    /// is blocked: the process's termination handler (or the timeout) resumes a continuation.
    static func run(now: Date = .now) async -> Outcome {
        await Task.detached(priority: .userInitiated) { await export(now: now) }.value
    }

    private enum Exit: Sendable { case exited, timedOut, launchFailed }

    private nonisolated static func export(now: Date) async -> Outcome {
            let file: URL
            let handle: FileHandle
            do {
                file = try ensureFolder().appendingPathComponent(fileName(at: now))
                guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
                    return .failed("Could not create the export file.")
                }
                handle = try FileHandle(forWritingTo: file)
            } catch {
                return .failed("Could not create the logs folder.")
            }
            defer { try? handle.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            process.arguments = arguments
            process.standardOutput = handle
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            let exit = await withCheckedContinuation { (c: CheckedContinuation<Exit, Never>) in
                // Resumed exactly once: by the exit, the timeout or a failed launch, whichever comes first.
                let resumed = OSAllocatedUnfairLock(initialState: false)
                let finish: @Sendable (Exit) -> Void = { e in
                    let first = resumed.withLock { done in
                        defer { done = true }
                        return !done
                    }
                    if first { c.resume(returning: e) }
                }
                process.terminationHandler = { _ in finish(.exited) }
                do { try process.run() } catch { return finish(.launchFailed) }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { finish(.timedOut) }
            }
            switch exit {
            case .launchFailed:
                try? FileManager.default.removeItem(at: file)
                return .failed("Could not run the log tool.")
            case .timedOut:
                process.terminate()
                try? FileManager.default.removeItem(at: file)
                return .failed("The export took too long and was stopped.")
            case .exited:
                break
            }
            let status = process.terminationStatus
            guard status == 0 else {
                try? FileManager.default.removeItem(at: file)
                return .failed("The log tool failed (exit \(status)).")
            }
            return .done(file)
    }
}

struct LogsSettingsView: View {
    @State private var exporting = false
    @State private var status: String?
    private static let log = Logger(subsystem: "dev.remora", category: "app")

    var body: some View {
        Form {
            Section {
                Text("Remora logs events, counts and error codes. It never logs what you type, read or ask.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Button("Open logs folder") { openFolder() }
                HStack {
                    Button("Export last 24 hours") { export() }.disabled(exporting)
                    if exporting {
                        ProgressView().controlSize(.small)
                        Text("Exporting…").foregroundStyle(.secondary)
                    } else if let status {
                        Text(status).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Button("Open Console") { openConsole() }
            }
        }
        .formStyle(.grouped)
    }

    private func openFolder() {
        do { NSWorkspace.shared.open(try LogExport.ensureFolder()) } catch {
            status = "Could not create the logs folder."
        }
    }

    private func export() {
        exporting = true
        status = nil
        Task {
            let outcome = await LogExport.run()
            exporting = false
            switch outcome {
            case .done(let file):
                status = "Exported \(file.lastPathComponent)."
                NSWorkspace.shared.activateFileViewerSelecting([file])
            case .failed(let message):
                Self.log.error("log export failed")
                status = message
            }
        }
    }

    private func openConsole() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Console") else {
            status = "Console wasn't found."
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
