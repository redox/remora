import Embeddings
import Foundation
import Storage
import os

/// Runs an `embeddings` job (no model call): one `EmbeddingIndexer` batch of up to 200 pending
/// rows, written through `DataGeneration.write` (F-11, F-12). With the embedder unavailable,
/// (no identity, or one with no dimension), vectors of deleted owners are still dropped and the job is `.skipped("unavailable")`; it never
/// waits for the pending count to fall.
public struct EmbeddingsPipeline: JobRunner {
    public static let batch = 200

    private let db: AppDatabase
    private let embedder: any Embedder
    private static let log = Logger(subsystem: "dev.remora", category: "embeddings")

    public init(db: AppDatabase, embedder: any Embedder) {
        self.db = db; self.embedder = embedder
    }

    public func run(_ job: Job, context: JobContext) async throws -> JobOutcome {
        guard job.kind == .embeddings else { return .skipped("wrong_kind") }
        guard EmbeddingIndexer.usable(await embedder.identity()) != nil else {
            _ = try DataGeneration.write(db, expected: context.generation) { try EmbeddingStore.deleteOrphans(in: $0) }
            return .skipped("unavailable")
        }
        let written = try await EmbeddingIndexer(db: db, embedder: embedder)
            .run(limit: Self.batch, at: context.now, generation: context.generation)
        Self.log.info("embeddings: \(written, privacy: .public) written")
        return .done
    }
}
