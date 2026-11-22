import Foundation

/// A running process with Remora's bundle id, as reported by the caller (e.g. from NSRunningApplication).
public struct RunningCopy: Equatable, Sendable {
    public var pid: Int32
    public var bundlePath: String?
    public var isTerminated: Bool
    /// nil when unknown (a process not launched through Launch Services).
    public var launchDate: Date?

    public init(pid: Int32, bundlePath: String?, isTerminated: Bool, launchDate: Date? = nil) {
        self.pid = pid
        self.bundlePath = bundlePath
        self.isTerminated = isTerminated
        self.launchDate = launchDate
    }

    /// Earliest launch first (an unknown date counts as earliest), then lowest PID.
    func precedes(_ other: RunningCopy) -> Bool {
        let a = launchDate ?? .distantPast, b = other.launchDate ?? .distantPast
        return a != b ? a < b : pid < other.pid
    }
}

public enum SingleInstance {
    /// The live copy this process must defer to, or nil when this copy survives. Callers pass only copies with the
    /// same bundle id. Two copies launched together each see the other, so only one that precedes this one
    /// (earlier launch, then lower PID) counts; the later copy quits. When this process is not in `running`,
    /// any other live copy wins.
    public static func otherInstance(ownPID: Int32, running: [RunningCopy]) -> RunningCopy? {
        let others = running.filter { $0.pid != ownPID && !$0.isTerminated }
        guard let own = running.first(where: { $0.pid == ownPID }) else { return others.first }
        return others.filter { $0.precedes(own) }.min { $0.precedes($1) }
    }
}
