import Foundation
import GRDB

/// The last nudge verdict per salient flag (`nudge_decisions`; cascades with the flag). The
/// nudge runner reads and records it inside its generation-checked write.
public struct NudgeDecisionStore: Sendable {
    private let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    public func decision(flagID: Int64) throws -> NudgeDecision? {
        try db.reader.read { try decision(flagID: flagID, in: $0) }
    }

    public func decision(flagID: Int64, in d: Database) throws -> NudgeDecision? {
        try NudgeDecision.fetchOne(d, key: flagID)
    }

    /// Inserts or replaces the flag's decision, except that `sent` is final: a later verdict never
    /// overwrites it (the flag must not be nudged twice).
    public func record(_ decision: NudgeDecision, in d: Database) throws {
        if decision.decision != .sent, try self.decision(flagID: decision.flagID, in: d)?.decision == .sent { return }
        var row = decision
        try row.save(d)
    }
}
