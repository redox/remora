import Capture
import Foundation
import GRDB
import Retrieval
import Storage

/// The open salient flags a nudge scan may triage, read in one transaction under the caller's
/// fresh exclusions (`SnapshotPolicy.current`, `.denyAll` when they cannot be loaded):
/// - the user's own `commitment`s and `todo`s seen within 72 h or due within 24 h;
/// - `event`s (anyone's) due in (now, now + 24 h];
/// - `email`s from someone else seen within 48 h.
///
/// A flag is left out when it was already `sent` or `unverified`; when it was `declined`, unless it
/// was seen again at least 24 h after that decision; and when none of the snapshots it cites still
/// exists and passes the policy (a flag citing nothing is left out too: there is nothing to check
/// its quote against). Dated first (soonest), then the most recently seen.
public enum NudgeCandidates {
    public static let ownSeenWithin: TimeInterval = 72 * 3_600
    public static let dueWithin: TimeInterval = 24 * 3_600
    public static let emailSeenWithin: TimeInterval = 48 * 3_600
    /// A declined flag returns once seen again this long after the decision.
    public static let declinedQuiet: TimeInterval = 24 * 3_600
    static let rows = 200

    public static func select(db: AppDatabase, policy: CapturePolicy, now: Date, calendar: Calendar,
                              limit: Int = 3) throws -> [SalientFlag] {
        guard !policy.deniesEverything, limit > 0 else { return [] }
        let dueEnd = now.addingTimeInterval(dueWithin)
        return try db.reader.read { d in
            // Decisions are applied before the LIMIT, so decided flags cannot starve new ones.
            let undecided = try SalientFlag.fetchAll(d, sql: """
                SELECT f.* FROM salient_flags f LEFT JOIN nudge_decisions n ON n.flag_id = f.id
                WHERE f.status = 'open' AND (
                    (f.kind IN ('commitment', 'todo') AND f.owner = 'user'
                        AND (f.last_seen_at >= ? OR (f.due_at > ? AND f.due_at <= ?)))
                    OR (f.kind = 'event' AND f.due_at > ? AND f.due_at <= ?)
                    OR (f.kind = 'email' AND f.owner = 'other' AND f.last_seen_at >= ?))
                AND (n.flag_id IS NULL
                     OR (n.decision = 'declined' AND julianday(f.last_seen_at) >= julianday(n.decided_at) + ?))
                ORDER BY f.due_at IS NULL, f.due_at, f.last_seen_at DESC, f.id DESC LIMIT ?
                """, arguments: [now.addingTimeInterval(-ownSeenWithin), now, dueEnd, now, dueEnd,
                                 now.addingTimeInterval(-emailSeenWithin), declinedQuiet / 86_400, rows])
            let allowed = try DerivedPolicy.allowedIDs(undecided.flatMap(\.snapshotIDs), policy: policy, in: d)
            return Array(undecided.filter { $0.snapshotIDs.contains(where: allowed.contains) }.prefix(limit))
        }
    }
}
