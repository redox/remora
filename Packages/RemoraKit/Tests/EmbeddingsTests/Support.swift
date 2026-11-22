import Foundation
import GRDB
import Storage
@testable import Embeddings

let t0 = Date(timeIntervalSince1970: 1_800_000_000)

struct Seeded { var chronicleID: Int64; var pageID: Int64; var factID: Int64 }

func seed(_ db: AppDatabase) throws -> Seeded {
    try db.writer.write { d in
        var c = Chronicle(level: .hour, periodKey: "2026-11-20T10", periodStart: t0, periodEnd: t0.addingTimeInterval(3600),
                          summary: "Budget meeting in Oslo with Ingrid", generatedAt: t0)
        try c.insert(d)
        var p = WikiPage(slug: "oslo-trip", type: .project, title: "Oslo trip", summary: "Travel planning for Oslo",
                         body: "Flights and hotel", firstSeen: t0, lastSeen: t0, updatedAt: t0)
        try p.insert(d)
        var f = WikiFact(slug: "oslo-trip", fact: "Hotel booked near the harbour", normKey: "hotel", subject: .user,
                         basis: .observedAction, worth: .core, validAt: t0, recordedAt: t0, lastConfirmedAt: t0)
        try f.insert(d)
        return Seeded(chronicleID: c.id!, pageID: p.id!, factID: f.id!)
    }
}

func count(_ db: AppDatabase, _ table: String = "embeddings") throws -> Int {
    try db.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
}

/// Counts calls and can run a hook while "embedding" (to simulate a delete-all mid-run).
final class HookEmbedder: Embedder, @unchecked Sendable {
    let base: HashingEmbedder
    var onEmbed: (@Sendable () throws -> Void)?
    init(base: HashingEmbedder = HashingEmbedder()) { self.base = base }
    func identity() async -> EmbedderIdentity? { await base.identity() }
    func embed(_ text: String) async throws -> [Float] {
        try onEmbed?()
        return try await base.embed(text)
    }
}

func exec(_ db: AppDatabase, _ sql: String, _ args: StatementArguments) throws {
    try db.writer.write { try $0.execute(sql: sql, arguments: args) }
}

func ownerTables(_ db: AppDatabase) throws -> [String] {
    try db.reader.read { try String.fetchAll($0, sql: "SELECT owner_table FROM embeddings ORDER BY owner_table") }
}

func storedHash(_ db: AppDatabase, _ table: String, _ id: Int64) throws -> String? {
    try db.reader.read {
        try String.fetchOne($0, sql: "SELECT content_hash FROM embeddings WHERE owner_table = ? AND owner_id = ?", arguments: [table, id])
    }
}

func seedUnembeddable(_ db: AppDatabase) throws {
    try db.writer.write { d in
        for i in 0..<250 {
            var c = Chronicle(level: .hour, periodKey: "k\(i)", periodStart: t0, periodEnd: t0, summary: "", generatedAt: t0)
            try c.insert(d)
        }
        var good = Chronicle(level: .hour, periodKey: "good", periodStart: t0, periodEnd: t0, summary: "Budget meeting in Oslo", generatedAt: t0)
        try good.insert(d)
    }
}

func factSourceHash(_ db: AppDatabase) throws -> String? {
    try db.reader.read { try EmbeddingIndexer.sources($0) }.first { $0.owner == .wikiFact }?.hash
}
