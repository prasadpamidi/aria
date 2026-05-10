#if canImport(NaturalLanguage) && (os(iOS) || os(macOS) || os(watchOS) || os(tvOS) || os(visionOS))

    import Aria
    import Foundation
    import NaturalLanguage

    // MARK: - NLEmbeddingEmbedder

    /// An `Embedder` backed by Apple's built-in `NLEmbedding`.
    ///
    /// Zero binary cost (the model ships with the OS), no download,
    /// usable on every Apple platform that has the NaturalLanguage
    /// framework. Quality is roughly 2019-era — fine for keyword recall
    /// and short-form similarity, weaker than modern transformer
    /// sentence embeddings on paraphrase tasks. Reach for an MLX or
    /// Core ML embedder when you need higher-fidelity multilingual
    /// retrieval.
    ///
    /// `init(language:)` returns `nil` when Apple does not ship a
    /// sentence embedding for the requested language. Currently
    /// supported: English, French, German, Italian, Portuguese,
    /// Spanish, Simplified Chinese.
    public final class NLEmbeddingEmbedder: Embedder, @unchecked Sendable {
        // MARK: Lifecycle

        /// Construct an embedder for `language`. Returns `nil` when no
        /// sentence embedding model exists for that language on the
        /// current OS.
        public init?(language: NLLanguage = .english) {
            guard let model = NLEmbedding.sentenceEmbedding(for: language) else {
                return nil
            }
            self.embedding = model
            self.dimensions = model.dimension
            self.modelIdentifier = "apple.nlembedding.sentence.\(language.rawValue)"
        }

        // MARK: Public

        public let dimensions: Int
        public let maxInputLength = 1000
        public let modelIdentifier: String

        public func embed(_ texts: [String]) async throws -> [[Float]] {
            texts.map { text in
                guard let vector = embedding.vector(for: text) else {
                    return Array(repeating: Float(0), count: self.dimensions)
                }
                return vector.map { Float($0) }
            }
        }

        // MARK: Private

        /// `NLEmbedding` is a class without a `Sendable` conformance,
        /// but its public surface is read-only and Apple's docs note it
        /// is safe to share across threads. We mark the wrapper
        /// `@unchecked Sendable` to opt into that guarantee explicitly.
        private let embedding: NLEmbedding
    }

#endif
