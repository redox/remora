import Capture
import Foundation
import GRDB
import Memory
import Testing
@testable import Assistant
import Storage

/// A flag with an owner, a person and a quote (the shared `seedFlag` has neither).
@discardableResult
func seedNudgeFlag(_ db: AppDatabase, _ kind: FlagKind, _ text: String, owner: FlagOwner = .user, person: String = "",
                   due: Date? = nil, status: FlagStatus = .open, seen: Date, quote: String = "",
                   snapshotIDs: [Int64]) throws -> SalientFlag {
    var f = SalientFlag(kind: kind, text: text, owner: owner, person: person, dueAt: due, status: status,
                        quote: quote, snapshotIDs: snapshotIDs,
                        dedupeKey: SalientFlagStore.dedupeKey(kind: kind, text: text, person: person),
                        createdAt: seen, lastSeenAt: seen)
    try db.writer.write { d in try f.insert(d) }
    return f
}

func recordDecision(_ db: AppDatabase, _ flag: SalientFlag, _ verdict: NudgeVerdict, at: Date) throws {
    try db.writer.write { d in
        try NudgeDecisionStore(db).record(NudgeDecision(flagID: flag.id!, decision: verdict,
                                                        flagLastSeenAt: flag.lastSeenAt, decidedAt: at), in: d)
    }
}

func setLastSeen(_ db: AppDatabase, _ flag: SalientFlag, _ at: Date) throws {
    try db.writer.write { d in
        try d.execute(sql: "UPDATE salient_flags SET last_seen_at = ? WHERE id = ?", arguments: [at, flag.id!])
    }
}

private func select(_ db: AppDatabase, _ now: Date, policy: CapturePolicy? = nil, limit: Int = 10) throws -> [String] {
    try NudgeCandidates.select(db: db, policy: policy ?? SnapshotPolicy.current(db), now: now, calendar: paris,
                               limit: limit).map(\.text)
}

@Suite struct NudgeCandidatesTests {
    let now = local("2026-11-20 10:00")

    @Test func selectsUserCommitmentsAndSoonEvents() throws {
        let db = try AppDatabase.inMemory()
        let s = try seedSnapshot(db, at: local("2026-11-20 09:00")).id!
        try seedNudgeFlag(db, .commitment, "user commitment seen 1 h ago", seen: local("2026-11-20 09:00"), snapshotIDs: [s])
        try seedNudgeFlag(db, .commitment, "other's commitment", owner: .other, person: "Marc",
                          seen: local("2026-11-20 09:00"), snapshotIDs: [s])
        try seedNudgeFlag(db, .event, "event due in 3 h", owner: .other, due: local("2026-11-20 13:00"),
                          seen: local("2026-11-17 09:00"), snapshotIDs: [s])
        try seedNudgeFlag(db, .event, "event due in 3 days", due: local("2026-11-23 10:00"),
                          seen: local("2026-11-20 09:00"), snapshotIDs: [s])
        try seedNudgeFlag(db, .event, "event already past", due: local("2026-11-20 09:30"),
                          seen: local("2026-11-20 09:00"), snapshotIDs: [s])
        try seedNudgeFlag(db, .todo, "done todo", status: .done, seen: local("2026-11-20 09:00"), snapshotIDs: [s])
        try seedNudgeFlag(db, .todo, "dismissed todo", status: .dismissed, seen: local("2026-11-20 09:00"), snapshotIDs: [s])
        try seedNudgeFlag(db, .email, "email from Ana seen 30 min ago", owner: .other, person: "Ana",
                          seen: local("2026-11-20 09:30"), snapshotIDs: [s])
        try seedNudgeFlag(db, .email, "email from Bo seen 3 days ago", owner: .other, person: "Bo",
                          seen: local("2026-11-17 09:30"), snapshotIDs: [s])
        try seedNudgeFlag(db, .email, "the user's own email", seen: local("2026-11-20 09:30"), snapshotIDs: [s])
        try seedNudgeFlag(db, .commitment, "stale commitment", seen: local("2026-11-16 09:00"), snapshotIDs: [s])
        try seedNudgeFlag(db, .todo, "stale todo due in 5 h", due: local("2026-11-20 15:00"),
                          seen: local("2026-11-16 09:00"), snapshotIDs: [s])
        try seedNudgeFlag(db, .todo, "todo due in 2 days", due: local("2026-11-22 15:00"),
                          seen: local("2026-11-16 09:00"), snapshotIDs: [s])

        // Dated first (soonest), then the most recently seen.
        #expect(try select(db, now) == ["event due in 3 h", "stale todo due in 5 h",
                                        "email from Ana seen 30 min ago", "user commitment seen 1 h ago"])
        // The default limit is 3.
        #expect(try NudgeCandidates.select(db: db, policy: SnapshotPolicy.current(db), now: now, calendar: paris).count == 3)
    }

    @Test func excludedSourceFlagsAreNotCandidates() throws {
        let db = try AppDatabase.inMemory()
        let notes = try seedSnapshot(db, at: local("2026-11-20 09:00")).id!
        let slack = try seedSnapshot(db, at: local("2026-11-20 09:10"), app: "Slack").id!
        let gone = try seedSnapshot(db, at: local("2026-11-20 09:20"), app: "Mail").id!
        try seedNudgeFlag(db, .commitment, "from Slack only", seen: local("2026-11-20 09:10"), snapshotIDs: [slack])
        try seedNudgeFlag(db, .commitment, "from Slack and Notes", seen: local("2026-11-20 09:05"), snapshotIDs: [slack, notes])
        try seedNudgeFlag(db, .commitment, "cites nothing", seen: local("2026-11-20 09:00"), snapshotIDs: [])
        try seedNudgeFlag(db, .commitment, "cites a deleted and a missing snapshot", seen: local("2026-11-20 09:20"),
                          snapshotIDs: [gone, 9_999])
        try db.writer.write { d in try d.execute(sql: "DELETE FROM snapshots WHERE id = ?", arguments: [gone]) }

        #expect(try select(db, now) == ["from Slack only", "from Slack and Notes"])
        try ExclusionStore(db).add("app:Slack")
        #expect(try select(db, now) == ["from Slack and Notes"])
        // Exclusions that cannot be loaded deny everything.
        #expect(try select(db, now, policy: .denyAll).isEmpty)
    }

    @Test func declinedReturnsOnlyAfterSeenAgain() throws {
        let db = try AppDatabase.inMemory()
        let s = try seedSnapshot(db, at: local("2026-11-20 09:00")).id!
        let declined = try seedNudgeFlag(db, .commitment, "declined", seen: local("2026-11-19 09:00"), snapshotIDs: [s])
        let sent = try seedNudgeFlag(db, .commitment, "sent", seen: local("2026-11-19 09:00"), snapshotIDs: [s])
        let unverified = try seedNudgeFlag(db, .commitment, "unverified", seen: local("2026-11-19 09:00"), snapshotIDs: [s])
        let decidedAt = local("2026-11-19 09:30")
        try recordDecision(db, declined, .declined, at: decidedAt)
        try recordDecision(db, sent, .sent, at: decidedAt)
        try recordDecision(db, unverified, .unverified, at: decidedAt)
        #expect(try select(db, now).isEmpty)

        // Seen again 23 h after the decision: still declined.
        for flag in [declined, sent, unverified] { try setLastSeen(db, flag, decidedAt.addingTimeInterval(23 * 3_600)) }
        #expect(try select(db, now).isEmpty)
        // Seen again 24 h after: the declined flag returns; sent and unverified never do.
        for flag in [declined, sent, unverified] { try setLastSeen(db, flag, decidedAt.addingTimeInterval(24 * 3_600)) }
        #expect(try select(db, now) == ["declined"])
    }
    @Test func decidedFlagsCannotStarveNewOnes() throws {
        let db = try AppDatabase.inMemory()
        let s = try seedSnapshot(db, at: local("2026-11-20 09:00")).id!
        // 205 sent flags, all due sooner than the new one (so they sort first).
        for i in 0..<205 {
            let f = try seedNudgeFlag(db, .event, "old \(i)", due: local("2026-11-20 11:00").addingTimeInterval(Double(i)),
                                      seen: local("2026-11-20 09:00"), snapshotIDs: [s])
            try recordDecision(db, f, .sent, at: local("2026-11-20 09:30"))
        }
        try seedNudgeFlag(db, .event, "new", due: local("2026-11-20 20:00"), seen: local("2026-11-20 09:00"), snapshotIDs: [s])
        #expect(try select(db, now) == ["new"])
    }

    @Test func sentIsNeverOverwritten() throws {
        let db = try AppDatabase.inMemory()
        let s = try seedSnapshot(db, at: local("2026-11-20 09:00")).id!
        let f = try seedNudgeFlag(db, .commitment, "c", seen: local("2026-11-20 09:00"), snapshotIDs: [s])
        try recordDecision(db, f, .sent, at: local("2026-11-20 09:30"))
        try recordDecision(db, f, .declined, at: local("2026-11-20 10:30"))
        try recordDecision(db, f, .unverified, at: local("2026-11-20 10:40"))
        #expect(try NudgeDecisionStore(db).decision(flagID: f.id!)?.decision == .sent)
    }
}
