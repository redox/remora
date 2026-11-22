import Foundation
import Storage

public enum BudgetLevel: Sendable, Equatable {
    /// Under 80 % of the daily background budget.
    case normal
    /// 80 % or more: only `hour`, `day_rollup`, `working_memory`, `morning_brief`,
    /// `evening_wrap` and `digest_rebuild` may use the cloud (`JobKind.softBudgetKinds`).
    case soft
    /// 100 % or more: no job uses the cloud (on-device and no-LLM work continues).
    case exhausted
}

/// The daily background token budget (`memory.dailyTokenBudget`, uncached tokens of background
/// cloud calls since local midnight). Foreground features never consult it.
public struct BudgetGate: Sendable {
    private let db: AppDatabase
    private let calendar: Calendar

    public init(db: AppDatabase, calendar: Calendar) { self.db = db; self.calendar = calendar }

    public func usedToday(now: Date) throws -> Int {
        try BackgroundUsage.today(db, now: now, calendar: calendar)
    }

    public func level(now: Date) throws -> BudgetLevel {
        Self.level(used: try usedToday(now: now), budget: MemorySettings(SettingsStore(db)).dailyTokenBudget())
    }

    public func allowsCloud(_ k: JobKind, now: Date) throws -> Bool {
        Self.allowsCloud(k, at: try level(now: now))
    }

    static func level(used: Int, budget: Int) -> BudgetLevel {
        if used >= budget { return .exhausted }
        return Double(used) >= Double(budget) * 0.8 ? .soft : .normal
    }

    static func allowsCloud(_ k: JobKind, at level: BudgetLevel) -> Bool {
        switch level {
        case .normal: true
        case .soft: JobKind.softBudgetKinds.contains(k)
        case .exhausted: false
        }
    }
}
