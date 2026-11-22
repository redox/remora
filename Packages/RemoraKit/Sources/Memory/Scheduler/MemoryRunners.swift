import Embeddings
import Foundation
import LLM
import Storage

/// The memory job runners (plan 4 Task 14), one per memory `JobKind`, built in one place so a test
/// can check that, with `ProactiveRunners`, every kind has a runner (a kind without one would sit
/// pending forever). Compaction and the forget-triggered `digest_rebuild` share one
/// `DigestPipeline`.
public enum MemoryRunners {
    /// `embedder` never requests model assets (compaction); `backgroundEmbedder` is the idle and
    /// on-power path allowed to download them (the embeddings job).
    public static func make(db: AppDatabase, llm: LLMService, embedder: any Embedder,
                            backgroundEmbedder: any Embedder, dbURL: URL?,
                            calendar: Calendar) -> [JobKind: any JobRunner] {
        let rollup = RollupPipeline(db: db, llm: llm, calendar: calendar)
        let digest = DigestPipeline(db: db, llm: llm, identity: IdentityStore(db), calendar: calendar)
        return [
            .workingMemory: WorkingMemoryPipeline(db: db, llm: llm, calendar: calendar),
            .timeLedger: TimeLedgerPipeline(db: db),
            .hour: HourPipeline(db: db, llm: llm, calendar: calendar),
            .dayRollup: rollup, .weekRollup: rollup, .monthRollup: rollup, .yearRollup: rollup,
            .wikiRewrite: WikiRewritePipeline(db: db, llm: llm, calendar: calendar),
            .embeddings: EmbeddingsPipeline(db: db, embedder: backgroundEmbedder),
            .styleNotes: StylePipeline(db: db, llm: llm, calendar: calendar),
            .identity: IdentityPipeline(db: db, llm: llm, calendar: calendar),
            .compaction: CompactionPipeline(db: db, dbURL: dbURL, llm: llm, embedder: embedder, digest: digest,
                                            calendar: calendar),
            .digestRebuild: DigestRebuildRunner(digest: digest),
        ]
    }
}
