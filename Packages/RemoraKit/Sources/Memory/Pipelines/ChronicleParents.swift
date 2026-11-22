import Foundation
import GRDB
import Storage

/// Tells the chronicles above a changed one that they are out of date.
enum ChronicleParents {
    /// For each parent (`ChronicleLevel.parents`) of the `level` chronicle starting at `start`:
    /// marks its row dirty when it exists (the planner requeues a dirty, done rollup). With no
    /// row, requeues its rollup job, but only when that job is `done` or `skipped`: a rollup that
    /// found no children must run again once a late child lands, while a pending or running job
    /// will see the child anyway and a failed one stays failed. Inside the caller's write.
    static func touch(_ level: ChronicleLevel, start: Date, db: AppDatabase, calendar: Calendar, now: Date,
                      in d: Database) throws {
        let store = ChronicleStore(db), jobs = JobStore(db)
        for parent in level.parents {
            let key = PeriodKey.key(parent, for: start, calendar: calendar)
            if try store.chronicle(parent, key: key, in: d) != nil {
                try store.markDirty(parent, key: key, in: d)
            } else {
                try jobs.requeue(kind: parent.jobKind, periodKey: key, now: now, ifStatusIn: [.done, .skipped], in: d)
            }
        }
    }
}
