#if canImport(NaturalLanguage) && (os(iOS) || os(macOS) || os(visionOS))

    import Aria
    import Foundation
    import NaturalLanguage
    import os

    // MARK: - NLContextualEmbedder

    /// An `Embedder` backed by Apple's `NLContextualEmbedding`.
    ///
    /// The successor to `NLEmbeddingEmbedder`, and a different class of
    /// model: a BERT-style transformer that reads the whole string,
    /// where `NLEmbedding` averages static per-word vectors and cannot
    /// tell a river bank from an investment bank.
    ///
    /// That difference is measurable rather than theoretical. Ranking
    /// tools with `NLEmbedding` scored 58% hit and 25% top-1 on Aria's
    /// selection eval — worse than plain lexical matching, because
    /// averaged word vectors put everything user-shaped near everything
    /// else. `ToolSelectionEval` exists to say whether this one does
    /// better; see `Tests/AriaAppleTests/ToolSelectionEvalTests`.
    ///
    /// **Assets are not resident.** Unlike `NLEmbedding`, the model is
    /// downloaded on demand — under 100MB, managed by the OS, shared
    /// across apps. `prepare()` performs that download; `embed` will
    /// throw until it has completed. Callers that need embeddings on a
    /// latency budget should prepare at launch rather than at first use.
    ///
    /// Token vectors are mean-pooled and L2-normalised. Mean pooling
    /// rather than CLS because `NLContextualEmbedding` exposes no
    /// classification token — the API vends one vector per token and
    /// leaves the sentence representation to the caller.
    @available(iOS 17.0, macOS 14.0, visionOS 1.0, *)
    public final class NLContextualEmbedder: Embedder, @unchecked Sendable {
        // MARK: Lifecycle

        /// Construct an embedder for `language`. Returns `nil` when
        /// Apple ships no contextual embedding covering it.
        public init?(language: NLLanguage = .english) {
            guard let embedding = NLContextualEmbedding(language: language) else {
                return nil
            }
            self.embedding = embedding
            self.language = language
        }

        deinit {
            self.embedding.unload()
        }

        // MARK: Public

        public var dimensions: Int {
            self.embedding.dimension
        }

        /// Characters, approximated from the model's token budget.
        ///
        /// `NLContextualEmbedding` caps input at
        /// `maximumSequenceLength` *tokens*, and the protocol speaks in
        /// characters. Four characters per token is the same
        /// approximation `HeuristicTokenCounter` uses, deliberately —
        /// two different guesses at the same quantity would be worse
        /// than one shared one.
        public var maxInputLength: Int {
            self.embedding.maximumSequenceLength * 4
        }

        public var modelIdentifier: String {
            "apple.nlcontextualembedding.\(self.embedding.modelIdentifier)"
        }

        /// `true` once the model can be used without a download.
        public var hasAssets: Bool {
            self.embedding.hasAvailableAssets
        }

        /// Download the model if needed and load it.
        ///
        /// Safe to call repeatedly; the work happens once. Separated
        /// from `init` because it can hit the network, and a failable
        /// initialiser that silently blocks on a download is a worse
        /// contract than one that makes the caller choose when.
        public func prepare() async throws {
            if self.loaded {
                return
            }
            if !self.embedding.hasAvailableAssets {
                try await self.requestAssets()
            }
            try self.embedding.load()
            self.loaded = true
        }

        public func embed(_ texts: [String]) async throws -> [[Float]] {
            try await self.prepare()
            return try texts.map { try self.vector(for: $0) }
        }

        // MARK: Private

        private let embedding: NLContextualEmbedding
        private let language: NLLanguage
        private var loaded = false

        private func requestAssets() async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                self.embedding.requestAssets { result, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard result == .available else {
                        continuation.resume(
                            throwing: AgentError.providerFailed(
                                "NLContextualEmbedding assets unavailable: \(String(describing: result))",
                                underlying: nil
                            )
                        )
                        return
                    }
                    continuation.resume()
                }
            }
        }

        /// Mean-pool the token vectors, then L2-normalise so cosine
        /// similarity reduces to a dot product and vectors from
        /// different-length inputs stay comparable.
        private func vector(for text: String) throws -> [Float] {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return Array(repeating: 0, count: self.dimensions)
            }

            let result = try embedding.embeddingResult(for: trimmed, language: self.language)
            var sum = [Double](repeating: 0, count: self.dimensions)
            var count = 0
            result.enumerateTokenVectors(in: trimmed.startIndex..<trimmed.endIndex) { vector, _ in
                guard vector.count == sum.count else {
                    return true
                }
                for index in vector.indices {
                    sum[index] += vector[index]
                }
                count += 1
                return true
            }

            guard count > 0 else {
                return Array(repeating: 0, count: self.dimensions)
            }
            let mean = sum.map { $0 / Double(count) }
            let norm = mean.reduce(0) { $0 + $1 * $1 }.squareRoot()
            guard norm > 0 else {
                return Array(repeating: 0, count: self.dimensions)
            }
            return mean.map { Float($0 / norm) }
        }
    }

#endif
