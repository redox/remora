import AppKit
import Input
import os
import Rewrite

/// 45 s after a rewrite is inserted, re-reads the field and records whether the text was kept,
/// edited or discarded (`RewriteEngine.recordOutcome` classifies and redacts). Before reading,
/// `mayRecord` re-checks the context (pause, exclusions, vaults, focus): when it fails, the field
/// is not read and the outcome is stored as unknown, with no final text. One task per output;
/// pending checks are dropped at quit. Never logs field text.
@MainActor
final class OutcomeCheckScheduler {
    private static let log = Logger(subsystem: "dev.remora", category: "rewrite")

    private let engine: RewriteEngine
    private let mayRecord: @MainActor (any FieldHandle) async -> Bool
    /// A re-scheduled output replaces its pending check; a finished check never drops its replacement.
    private let tasks = KeyedTasks<Int64>()
    private var quitObserver: (any NSObjectProtocol)?

    init(engine: RewriteEngine, mayRecord: @escaping @MainActor (any FieldHandle) async -> Bool) {
        self.engine = engine
        self.mayRecord = mayRecord
        quitObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelAll() }
        }
    }

    func schedule(id: Int64, handle: any FieldHandle, inserted: String, after delay: Duration = .seconds(45)) {
        let engine = engine
        tasks.run(id) { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let allowed = await self?.mayRecord(handle), !Task.isCancelled else { return }
            // `value()` is synchronous AX IPC (bounded by the messaging timeout): off the main actor.
            let now = allowed ? await Task.detached(priority: .utility) { handle.value() }.value : nil
            guard !Task.isCancelled else { return }
            do {
                let outcome = try await engine.recordOutcome(outputID: id, inserted: inserted, fieldNow: now, at: Date())
                Self.log.info("outcome recorded: \(outcome.map { String(describing: $0) } ?? "unknown", privacy: .public)")
            } catch {
                Self.log.error("outcome not recorded: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    /// Drops one pending check (an Edit-mode round superseded by a later one).
    func cancel(id: Int64) { tasks.cancel(id) }

    func cancelAll() { tasks.cancelAll() }
}
