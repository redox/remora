import Foundation
import Synchronization

/// Bounds interactive work (the rewrite key's memory context, query expansion) by a deadline.
public enum TimeBound {
    /// `operation`'s value, or nil once `timeout` has passed (or the caller was cancelled) first.
    ///
    /// The operation runs in its own task, which is cancelled when the deadline wins. The caller
    /// never waits for it to wind down, so work that ignores cancellation (a synchronous database
    /// read, a model call that is slow to stop) cannot hold the caller past the deadline.
    public static func run<T: Sendable>(within timeout: Duration,
                                        _ operation: @escaping @Sendable () async -> T) async -> T? {
        let race = Race<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
                race.start(c, timeout: timeout, operation: operation)
            }
        } onCancel: {
            race.finish(nil)
        }
    }
}

/// One operation against one timer: the first to finish resumes the caller, exactly once.
private final class Race<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T?, Never>?
        var done = false
        var tasks: [Task<Void, Never>] = []
    }

    private let state = Mutex(State())

    func start(_ c: CheckedContinuation<T?, Never>, timeout: Duration,
               operation: @escaping @Sendable () async -> T) {
        let finished = state.withLock { s in
            if !s.done { s.continuation = c }
            return s.done
        }
        // Cancelled before it started.
        if finished { c.resume(returning: nil); return }
        let work = Task { self.finish(await operation()) }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            self.finish(nil)
        }
        let cancelNow = state.withLock { s in
            if !s.done { s.tasks = [work, timer] }
            return s.done
        }
        if cancelNow { work.cancel(); timer.cancel() }
    }

    func finish(_ value: T?) {
        let (continuation, tasks) = state.withLock { s -> (CheckedContinuation<T?, Never>?, [Task<Void, Never>]) in
            guard !s.done else { return (nil, []) }
            s.done = true
            defer { s.continuation = nil; s.tasks = [] }
            return (s.continuation, s.tasks)
        }
        for task in tasks { task.cancel() }
        continuation?.resume(returning: value)
    }
}
