import Foundation
import GRDB
import LLM
import LLMTestSupport
import Storage
import Testing
@testable import Memory

// The digest after a forget (Task 10 review carry): only the digest is rebuilt, never a full
// compaction; when the cloud is denied a dirty flag makes the next compaction rebuild it.

private func digestReply(_ text: String) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: ["digest": text]), as: UTF8.self)
}

private func seedDayChronicle(_ db: AppDatabase) throws {
    try db.writer.write { d in
        let start = date(2026, 11, 20)
        try ChronicleStore(db).upsert(Chronicle(level: .day, periodKey: "2026-11-20", periodStart: start,
                                                periodEnd: date(2026, 11, 21), summary: "Prepared the offsite.",
                                                generatedAt: start), in: d)
    }
}

private func digestEnv() throws -> CompactionEnv {
    let env = try compactionEnv(.bySchema(["memory_digest": digestReply("### Current focus\nThe offsite")]))
    try seedDayChronicle(env.db)
    // An open loop compaction would check: the forget path must not.
    _ = try seedFlag(env.db, .todo, "Renew the passport", created: cpNow.addingTimeInterval(-20 * 86_400))
    return env
}

private func digestCount(_ env: CompactionEnv) -> Int {
    env.fake.requests.filter { schemaName($0) == "memory_digest" }.count
}

@Test func forgetRebuildsOnlyTheDigestOnce() async throws {
    let env = try digestEnv()
    // A digest from earlier tonight: a compaction would skip the rebuild.
    _ = try await env.compaction.compact(context: compactionContext())
    let before = env.fake.requests.count
    let scheduler = MemoryScheduler(db: env.db, runners: [.digestRebuild: DigestRebuildRunner(digest: env.digest)],
                                    planner: nil, calendar: paris, now: { cpNow.addingTimeInterval(600) })
    let report = await ForgetFollowUp.rebuildDigest(db: env.db, scheduler: scheduler,
                                                    signals: signals(now: cpNow.addingTimeInterval(600)), calendar: paris)
    #expect(report.ran == [.digestRebuild])
    let after = Array(env.fake.requests.dropFirst(before))
    #expect(after.count == 1)
    #expect(after.map(schemaName) == ["memory_digest"])
    #expect(try DigestPipeline.dirtySince(env.db) == nil)
    #expect(try await env.db.reader.read { d in try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM memory_digest") } == 2)
}

@Test func cloudDeniedForgetLeavesDirtyFlagThatCompactionHonours() async throws {
    let env = try digestEnv()
    _ = try await env.compaction.compact(context: compactionContext())
    #expect(digestCount(env) == 1)
    // Signed out: the gate denies the rebuild; the flag stays.
    let scheduler = MemoryScheduler(db: env.db, runners: [.digestRebuild: DigestRebuildRunner(digest: env.digest)],
                                    planner: nil, calendar: paris, now: { cpNow.addingTimeInterval(600) })
    let report = await ForgetFollowUp.rebuildDigest(db: env.db, scheduler: scheduler,
                                                    signals: signals(now: cpNow.addingTimeInterval(600), account: false),
                                                    calendar: paris)
    #expect(report.ran.isEmpty)
    #expect(digestCount(env) == 1)
    #expect(try DigestPipeline.dirtySince(env.db) != nil)
    // The runner itself, with the cloud denied, does nothing either.
    let job = Job(kind: .digestRebuild, periodKey: "2026-11-21", nextRunAt: cpNow, createdAt: cpNow)
    #expect(try await DigestRebuildRunner(digest: env.digest).run(job, context: compactionContext(cloudAllowed: false))
            == .skipped("cloud_denied"))
    #expect(try DigestPipeline.dirtySince(env.db) != nil)

    // The same night, a digest already exists, yet the dirty flag forces the rebuild.
    let again = try await env.compaction.compact(context: compactionContext(now: cpNow.addingTimeInterval(1_800)))
    #expect(again.digestRebuilt)
    #expect(digestCount(env) == 2)
    #expect(try DigestPipeline.dirtySince(env.db) == nil)
}

@Test func forgetDuringRebuildKeepsTheFlag() async throws {
    let env = try digestEnv()
    try DigestPipeline.markDirty(env.db, at: cpNow)
    // A newer forget than the one the rebuild started from: its mark survives.
    try DigestPipeline.clearDirty(env.db, ifMarkedAt: cpNow.addingTimeInterval(-60))
    #expect(try DigestPipeline.dirtySince(env.db) == cpNow)
    try DigestPipeline.clearDirty(env.db, ifMarkedAt: cpNow)
    #expect(try DigestPipeline.dirtySince(env.db) == nil)
}

@Test func dirtyDigestWithNothingLeftIsDeleted() async throws {
    let env = try compactionEnv(.bySchema(["memory_digest": digestReply("### Current focus\nThe offsite")]))
    try seedDayChronicle(env.db)
    _ = try await env.compaction.compact(context: compactionContext())
    let pointing = "SELECT COUNT(*) FROM llm_calls WHERE artifact_table = 'memory_digest'"
    #expect(try await env.db.reader.read { d in try Int.fetchOne(d, sql: pointing) } == 1)
    // Everything it was built from is forgotten.
    try await env.db.writer.write { d in try d.execute(sql: "DELETE FROM chronicle") }
    try DigestPipeline.markDirty(env.db, at: cpNow.addingTimeInterval(60))
    let rebuilt = try await env.digest.rebuild(context: compactionContext(now: cpNow.addingTimeInterval(120)))
    #expect(rebuilt == nil)
    #expect(try await env.db.reader.read { d in try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM memory_digest") } == 0)
    #expect(try DigestPipeline.dirtySince(env.db) == nil)
    #expect(try await env.db.reader.read { d in try Int.fetchOne(d, sql: pointing) } == 0)
}
