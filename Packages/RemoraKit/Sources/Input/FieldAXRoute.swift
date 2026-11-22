import Foundation

/// Where a focused-field Accessibility call runs.
///
/// Another app's field is reached by IPC, so the call runs on the shared AX queue (bounded by the
/// messaging timeout, never blocking the main thread). Remora's own field (the onboarding practice
/// box) is reached in-process: AppKit handles the request on the calling thread and its text
/// system requires the main thread, so the call must run there.
enum FieldAXRoute: Equatable {
    case axQueue, mainThread

    static func route(fieldPID: pid_t, ownPID: pid_t) -> FieldAXRoute {
        fieldPID == ownPID ? .mainThread : .axQueue
    }
}

/// Runs work synchronously on the main thread: inline when already there, otherwise waiting for
/// the main queue. Only for in-process Accessibility calls on Remora's own windows.
enum MainThreadRunner {
    static func sync<T>(_ work: () -> T) -> T {
        if Thread.isMainThread { return work() }
        return DispatchQueue.main.sync(execute: work)
    }
}
