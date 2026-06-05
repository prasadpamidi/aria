#if canImport(NaturalLanguage) && (os(iOS) || os(macOS) || os(watchOS) || os(tvOS) || os(visionOS))

    import Aria
    import Foundation
    import NaturalLanguage
    import os

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
            // Serialize: `NLEmbedding.vector(for:)` crashes with
            // `EXC_BAD_ACCESS` and libmalloc heap corruption under
            // concurrent access despite Apple's docs claiming
            // thread-safety. `OSAllocatedUnfairLock.withLock` is the
            // async-safe scoped-locking primitive; the closure body is
            // sync (no awaits inside) so it satisfies the no-suspend
            // rule and serializes the embedder calls.
            self.lock.withLock {
                texts.map { text in
                    guard let vector = embedding.vector(for: text) else {
                        return Array(repeating: Float(0), count: self.dimensions)
                    }
                    return vector.map { Float($0) }
                }
            }
        }

        // MARK: Private

        private let embedding: NLEmbedding
        private let lock = OSAllocatedUnfairLock()
    }

#endif
