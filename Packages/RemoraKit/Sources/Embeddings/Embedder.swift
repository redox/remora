import Storage

public enum EmbeddingError: Error, Equatable {
    case emptyInput
    case unavailable
}

public protocol Embedder: Sendable {
    /// nil = the model is unavailable (no assets, load failure).
    func identity() async -> EmbedderIdentity?
    /// An L2-normalised vector of `identity().dimension` floats.
    func embed(_ text: String) async throws -> [Float]
}
