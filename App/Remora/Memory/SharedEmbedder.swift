import Embeddings
import Foundation
import Storage

/// The app's one `NLContextualEmbedding` behind `Embedder`, shared by the rewrite path, compaction
/// and the embeddings job.
///
/// It never requests assets on its own (`NLEmbedder(requestAssetsIfMissing: false)`). Only
/// `requestAssets()` may download them, and it is called only from an explicit user action in
/// Settings › Memory or by the embeddings job (`OnPowerEmbedder`, idle and on power). The request
/// runs in a fresh instance that is swapped in only after its load attempt is over: `NLEmbedder`
/// latches its first attempt, so the rewrite path can never trigger a download.
actor SharedEmbedder: Embedder {
    private var current = NLEmbedder(requestAssetsIfMissing: false)
    private var request = SingleFlight<Task<(NLEmbedder, EmbedderIdentity?), Never>>()

    func identity() async -> EmbedderIdentity? { await current.identity() }

    func embed(_ text: String) async throws -> [Float] { try await current.embed(text) }

    /// Whether the model's assets are on disk, without loading the model or requesting them.
    nonisolated func modelDownloaded() -> Bool { NLEmbedder.assetsDownloaded() }

    /// Loads the model, downloading its assets if missing. Concurrent callers share one request;
    /// a late waiter never clears a newer request (`SingleFlight`).
    func requestAssets() async -> EmbedderIdentity? {
        if let id = await current.identity() { return id }
        let (task, token) = request.join {
            Task {
                let fresh = NLEmbedder(requestAssetsIfMissing: true)
                return (fresh, await fresh.identity())
            }
        }
        let (fresh, id) = await task.value
        request.finish(token)
        if id != nil { current = fresh }
        return id
    }
}

/// The embeddings job's view of `SharedEmbedder`: it may request the assets (the job runs only
/// when idle and on power). With no assets after the request, the job skips (`unavailable`) and is
/// planned again at most once an hour: it never loops.
struct OnPowerEmbedder: Embedder {
    let shared: SharedEmbedder

    func identity() async -> EmbedderIdentity? { await shared.requestAssets() }
    func embed(_ text: String) async throws -> [Float] { try await shared.embed(text) }
}
