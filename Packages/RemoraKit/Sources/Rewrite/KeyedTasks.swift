/// At most one task per key; scheduling a key again cancels the previous task. A task forgets
/// itself when it ends, unless it was replaced in the meantime (its key then belongs to the newer task).
@MainActor
public final class KeyedTasks<Key: Hashable & Sendable> {
    private var tasks: [Key: (token: UInt64, task: Task<Void, Never>)] = [:]
    private var nextToken: UInt64 = 0

    public init() {}

    @discardableResult
    public func run(_ key: Key, _ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        tasks[key]?.task.cancel()
        nextToken += 1
        let token = nextToken
        // Starts on the main actor only after this call returns, so the entry below exists by then.
        let task = Task { [weak self] in
            await operation()
            self?.finished(key, token)
        }
        tasks[key] = (token, task)
        return task
    }

    public func isPending(_ key: Key) -> Bool { tasks[key] != nil }

    public func cancel(_ key: Key) { tasks.removeValue(forKey: key)?.task.cancel() }

    public func cancelAll() {
        tasks.values.forEach { $0.task.cancel() }
        tasks.removeAll()
    }

    private func finished(_ key: Key, _ token: UInt64) {
        if tasks[key]?.token == token { tasks[key] = nil }
    }
}
