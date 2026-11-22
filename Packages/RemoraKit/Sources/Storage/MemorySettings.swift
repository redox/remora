import Foundation
import GRDB
import os

/// The language memory summaries, wiki, identity and digest are written in.
public enum MemoryLanguage: String, Codable, Sendable, CaseIterable {
    case en, fr

    public var name: String {
        switch self {
        case .en: "English"
        case .fr: "French"
        }
    }
}

/// How long raw captures are kept.
public enum RetentionSetting: Codable, Sendable, Equatable {
    case days(Int)
    case forever

    public static let dayRange = 7...365

    /// `.days(n)` with `n` clamped to 7…365.
    public static func days(clamping n: Int) -> RetentionSetting {
        .days(min(max(n, dayRange.lowerBound), dayRange.upperBound))
    }

    var clamped: RetentionSetting {
        if case .days(let n) = self { return .days(clamping: n) }
        return self
    }
}

/// Exponential backoff after a usage-limit error: background cloud jobs wait until `until`,
/// then one probe job runs. Any completed cloud call resets it.
public struct UsageBackoff: Codable, Sendable, Equatable {
    public var step: Int
    public var until: Date?

    /// 15 min, 30 min, 1 h, 2 h, 4 h, 8 h, then 12 h (cap).
    public static let ladder: [TimeInterval] = [900, 1_800, 3_600, 7_200, 14_400, 28_800, 43_200]

    public init(step: Int = 0, until: Date? = nil) { self.step = step; self.until = until }

    public mutating func recordLimit(at date: Date) {
        until = date.addingTimeInterval(Self.ladder[min(max(step, 0), Self.ladder.count - 1)])
        step += 1
    }

    public mutating func recordSuccess() { self = UsageBackoff() }

    public func allowsProbe(at date: Date) -> Bool {
        guard let until else { return true }
        return date >= until
    }
}

/// Plan 4 memory settings, stored as JSON settings. An unreadable value yields the default and
/// logs the key name (never the value).
public struct MemorySettings: Sendable {
    public static let enabledKey = "memory.enabled"
    public static let languageKey = "memory.language"
    public static let retentionKey = "memory.retention"
    public static let dailyTokenBudgetKey = "memory.dailyTokenBudget"
    public static let backoffKey = "memory.backoff"

    public static let defaultRetention = RetentionSetting.days(30)
    public static let defaultDailyTokenBudget = 750_000

    private static let log = Logger(subsystem: "dev.remora", category: "memory")
    private let settings: SettingsStore

    public init(_ s: SettingsStore) { settings = s }

    public func enabled() -> Bool { read(Bool.self, Self.enabledKey) ?? true }
    public func setEnabled(_ on: Bool) throws { try settings.setValue(on, forKey: Self.enabledKey) }
    public func setEnabled(_ on: Bool, in d: Database) throws { try settings.setValue(on, forKey: Self.enabledKey, in: d) }

    public func language() -> MemoryLanguage { read(MemoryLanguage.self, Self.languageKey) ?? .en }
    public func setLanguage(_ l: MemoryLanguage) throws { try settings.setValue(l, forKey: Self.languageKey) }
    public func setLanguage(_ l: MemoryLanguage, in d: Database) throws {
        try settings.setValue(l, forKey: Self.languageKey, in: d)
    }

    public func retention() -> RetentionSetting {
        (read(RetentionSetting.self, Self.retentionKey) ?? Self.defaultRetention).clamped
    }
    public func setRetention(_ r: RetentionSetting) throws { try settings.setValue(r.clamped, forKey: Self.retentionKey) }
    public func setRetention(_ r: RetentionSetting, in d: Database) throws {
        try settings.setValue(r.clamped, forKey: Self.retentionKey, in: d)
    }

    /// Uncached background tokens per local day; a non-positive stored value is unusable.
    public func dailyTokenBudget() -> Int {
        guard let v = read(Int.self, Self.dailyTokenBudgetKey) else { return Self.defaultDailyTokenBudget }
        guard v > 0 else {
            Self.log.error("unusable setting \(Self.dailyTokenBudgetKey, privacy: .public); using the default")
            return Self.defaultDailyTokenBudget
        }
        return v
    }
    public func setDailyTokenBudget(_ n: Int) throws { try settings.setValue(n, forKey: Self.dailyTokenBudgetKey) }
    public func setDailyTokenBudget(_ n: Int, in d: Database) throws {
        try settings.setValue(n, forKey: Self.dailyTokenBudgetKey, in: d)
    }

    public func backoff() -> UsageBackoff { read(UsageBackoff.self, Self.backoffKey) ?? UsageBackoff() }
    public func backoff(in d: Database) -> UsageBackoff {
        read(UsageBackoff.self, Self.backoffKey) { try settings.value(UsageBackoff.self, forKey: Self.backoffKey, in: d) }
            ?? UsageBackoff()
    }
    public func setBackoff(_ b: UsageBackoff) throws { try settings.setValue(b, forKey: Self.backoffKey) }
    public func setBackoff(_ b: UsageBackoff, in d: Database) throws {
        try settings.setValue(b, forKey: Self.backoffKey, in: d)
    }

    private func read<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        read(type, key) { try settings.value(type, forKey: key) }
    }

    private func read<T>(_ type: T.Type, _ key: String, _ fetch: () throws -> T?) -> T? {
        do {
            return try fetch()
        } catch {
            Self.log.error("unreadable setting \(key, privacy: .public); using the default")
            return nil
        }
    }
}

/// Background LLM usage for the daily budget. Storage cannot import `LLM`, so the foreground
/// job types are listed by raw value (`LLMTests.backgroundSetMatchesStorage` keeps them in sync
/// with `JobType.isBackground`).
public enum BackgroundUsage {
    public static let foregroundJobTypes: Set<String> = [
        "rewrite", "edit_mode", "chat", "dictation_cleanup", "query_expansion", "chat_fold",
    ]

    /// Cloud backends (`siwc`, `api_key`): on-device calls cost nothing.
    public static let cloudBackends: Set<String> = ["siwc", "api_key"]

    /// True when a cloud call (`siwc`/`api_key`) completed with `started_at >= since`: the usage
    /// limit is over, so the backoff resets.
    public static func completedCloudCall(since: Date, in d: Database) throws -> Bool {
        let backends = cloudBackends.sorted()
        var arguments: StatementArguments = [LLMCallStatus.completed.rawValue, since]
        arguments += StatementArguments(backends)
        return try Bool.fetchOne(d, sql: """
            SELECT 1 FROM llm_calls WHERE status = ? AND started_at >= ?
              AND backend IN (\(Array(repeating: "?", count: backends.count).joined(separator: ",")))
            LIMIT 1
            """, arguments: arguments) ?? false
    }

    /// `input − cached + output` tokens of background calls on a cloud backend, from local
    /// midnight (of `calendar`) to the next midnight.
    public static func today(_ db: AppDatabase, now: Date, calendar: Calendar) throws -> Int {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? now.addingTimeInterval(86_400)
        let foreground = foregroundJobTypes.sorted()
        let backends = cloudBackends.sorted()
        let fgMarks = Array(repeating: "?", count: foreground.count).joined(separator: ",")
        let beMarks = Array(repeating: "?", count: backends.count).joined(separator: ",")
        var arguments: StatementArguments = [start, end]
        arguments += StatementArguments(foreground)
        arguments += StatementArguments(backends)
        return try db.reader.read { d in
            try Int.fetchOne(d, sql: """
                SELECT COALESCE(SUM(MAX(input_tokens - cached_input_tokens, 0) + output_tokens), 0)
                FROM llm_calls
                WHERE started_at >= ? AND started_at < ?
                  AND job_type NOT IN (\(fgMarks)) AND backend IN (\(beMarks))
                """, arguments: arguments) ?? 0
        }
    }
}
