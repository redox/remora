import Foundation
import Storage

/// Chat turns, summaries and inbox messages are kept 90 days (pinned). The app prunes at launch,
/// then once a day; `chat.lastPruneAt` records the last run.
public enum ChatRetention {
    public static let days = 90
    public static let interval: TimeInterval = 24 * 3_600
    public static let lastPruneKey = "chat.lastPruneAt"

    /// Never run, a day or more ago, or in the future (the clock moved back).
    public static func isDue(lastPruneAt: Date?, now: Date) -> Bool {
        guard let last = lastPruneAt else { return true }
        return last > now || now.timeIntervalSince(last) >= interval
    }

    /// Prunes when due and records the run. Returns the rows removed, or nil when not due.
    @discardableResult
    public static func pruneIfDue(db: AppDatabase, now: Date) throws -> Int? {
        let settings = SettingsStore(db)
        let last = try? settings.value(Date.self, forKey: lastPruneKey)
        guard isDue(lastPruneAt: last ?? nil, now: now) else { return nil }
        let removed = try ChatStore(db).prune(olderThan: now.addingTimeInterval(-Double(days) * 86_400))
        try settings.setValue(now, forKey: lastPruneKey)
        return removed
    }
}
