import Foundation
import OSLog
import Storage
@preconcurrency import NaturalLanguage

/// `NLContextualEmbedding(script: .latin)` behind the `Embedder` protocol. The model object never
/// leaves the actor. Text is cut to 1,000 characters at a word boundary, token vectors are
/// mean-pooled and L2-normalised. Model loading is attempted once: `attempted` latches for the
/// actor's life, so assets that arrive later need a new instance.
public actor NLEmbedder: Embedder {
    static let maxCharacters = 1_000
    private static let logger = Logger(subsystem: "app.remora", category: "embeddings")

    private let requestAssetsIfMissing: Bool
    private var model: NLContextualEmbedding?
    private var resolved: EmbedderIdentity?
    private var attempted = false

    public init(requestAssetsIfMissing: Bool) { self.requestAssetsIfMissing = requestAssetsIfMissing }

    /// Whether the model's assets are on disk. Neither loads the model nor requests the assets.
    public nonisolated static func assetsDownloaded() -> Bool {
        NLContextualEmbedding(script: .latin)?.hasAvailableAssets ?? false
    }

    public func identity() async -> EmbedderIdentity? {
        await prepare()
        return resolved
    }

    public func embed(_ text: String) async throws -> [Float] {
        await prepare()
        guard let model, let resolved else { throw EmbeddingError.unavailable }
        let capped = Self.capped(text)
        guard !capped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw EmbeddingError.emptyInput }
        let result = try model.embeddingResult(for: capped, language: nil)
        var sum = [Double](repeating: 0, count: resolved.dimension)
        var tokens = 0
        result.enumerateTokenVectors(in: capped.startIndex..<capped.endIndex) { vector, _ in
            guard vector.count == sum.count else { return true }
            for i in vector.indices { sum[i] += vector[i] }
            tokens += 1
            return true
        }
        guard tokens > 0 else { throw EmbeddingError.emptyInput }
        let mean = sum.map { Float($0 / Double(tokens)) }
        let norm = mean.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0, norm.isFinite else { throw EmbeddingError.emptyInput }
        return mean.map { $0 / norm }
    }

    /// At most 1,000 characters, cut back to the last whitespace when the text is longer.
    nonisolated static func capped(_ text: String) -> String {
        guard text.count > maxCharacters else { return text }
        let head = String(text.prefix(maxCharacters))
        if text[head.endIndex].isWhitespace { return head }
        guard let cut = head.lastIndex(where: { $0.isWhitespace }) else { return head }
        return String(head[..<cut])
    }

    private func prepare() async {
        guard !attempted else { return }
        attempted = true
        guard let candidate = NLContextualEmbedding(script: .latin) else {
            Self.logger.error("embedding model unavailable code=no_model")
            return
        }
        do {
            if !candidate.hasAvailableAssets {
                guard requestAssetsIfMissing else {
                    Self.logger.error("embedding model unavailable code=no_assets")
                    return
                }
                _ = try await candidate.requestAssets()
            }
            try candidate.load()
            // A model reporting no dimension would make every vector a tombstone; treat it as absent.
            guard candidate.dimension > 0 else {
                Self.logger.error("embedding model unavailable code=no_dimension")
                return
            }
        } catch {
            Self.logger.error("embedding model load failed code=load_failed")
            return
        }
        model = candidate
        resolved = EmbedderIdentity(modelID: candidate.modelIdentifier, revision: candidate.revision,
                                    dimension: candidate.dimension)
    }
}
