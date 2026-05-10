import Foundation

// MARK: - Embedder

/// Turns text into fixed-dimensional vector embeddings.
///
/// Aria's `MemoryStore` and any RAG middleware compose an `Embedder`
/// with a `VectorStore`: the embedder produces vectors, the store
/// indexes and searches them. Implementations are platform-specific
/// (Apple ships `NLEmbeddingEmbedder`; consumers may add Core ML or
/// MLX-backed adapters).
public protocol Embedder: Sendable {
    /// Number of components in each output vector.
    var dimensions: Int { get }

    /// Soft cap on input length per call (in characters). Implementations
    /// that have a token-aware budget should chunk or truncate
    /// internally; consumers use this only to surface diagnostics.
    var maxInputLength: Int { get }

    /// Stable identifier for the underlying model. Used by stores to
    /// guard against mixing vectors from incompatible embedders.
    var modelIdentifier: String { get }

    /// Embed a batch of texts. The output count matches the input count
    /// and each inner array has `dimensions` components.
    func embed(_ texts: [String]) async throws -> [[Float]]
}

extension Embedder {
    /// Convenience: embed a single string.
    public func embed(_ text: String) async throws -> [Float] {
        let result = try await self.embed([text])
        guard let vector = result.first else {
            throw AgentError.providerFailed(
                "Embedder returned no vectors for non-empty input",
                underlying: nil
            )
        }
        return vector
    }
}
