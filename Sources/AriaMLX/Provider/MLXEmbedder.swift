#if ARIA_MLX
    import Aria
    import Foundation
    import MLX
    import MLXEmbedders
    import MLXLMCommon

    // MARK: - MLXEmbedder

    /// An `Embedder` backed by an MLX embedding model.
    ///
    /// The quality tier above Apple's built-ins. `NLEmbedding` averages
    /// static per-word vectors and measured *worse than plain lexical
    /// matching* on Aria's tool-selection eval (58% hit, 25% top-1
    /// against lexical's 67% / 58%) — it puts everything user-shaped
    /// near everything else. These are real sentence encoders trained
    /// for retrieval.
    ///
    /// `mlx-swift-lm` was already in the dependency graph behind the
    /// `MLX` trait, so this is a wrapper rather than a new dependency.
    /// Its registry covers BERT (BGE, GTE, MiniLM, E5, Snowflake),
    /// Nomic BERT, Qwen3, Gemma3 and LFM2 — including LFM2 ColBERT.
    ///
    /// Pick a model by weighing download against quality:
    ///
    /// | model                 | params | notes                        |
    /// |-----------------------|--------|------------------------------|
    /// | `.bgeMicro`           |    17M | smallest useful               |
    /// | `.bgeSmall`           |    33M | strong default                |
    /// | `.miniLM`             |    23M | 2021 baseline, widely cited   |
    /// | `.lfm2Embedding4bit`  |   350M | quantised, higher fidelity    |
    /// | `.qwen3Embedding4bit` |   600M | strongest here, largest       |
    ///
    /// On Aria's tool-selection corpus, `.bgeSmall` answered every
    /// case (100% hit, 0.76 MRR) against lexical's 67% / 0.61 and
    /// `NLEmbedding`'s 58% / 0.39 — and fused with lexical reached
    /// 0.79 MRR with nothing misled. See `MLXEmbedderEvalTests`.
    ///
    /// That is one corpus of twelve queries, so re-run
    /// `ToolSelectionEval` against your own tool surface before
    /// treating the ordering as settled. This harness exists because
    /// the last three tuning decisions here were intuition that field
    /// data later contradicted.
    public actor MLXEmbedder: Embedder {
        // MARK: Lifecycle

        /// - Parameters:
        ///   - model: Which registered model to load.
        ///   - downloader: Fetches weights. Shares the app's Hub client
        ///     so embedding models download through the same path,
        ///     cache and progress reporting as chat models.
        ///   - normalize: L2-normalise outputs so cosine similarity
        ///     reduces to a dot product. On by default — retrieval
        ///     models are trained normalised, and consumers compare
        ///     with cosine.
        public init(
            model: Model = .bgeSmall,
            downloader: MLXModelDownloader = .init(),
            normalize: Bool = true
        ) {
            self.model = model
            self.downloader = downloader
            self.normalize = normalize
        }

        // MARK: Public

        /// Registered models worth reaching for, with their Hub ids.
        ///
        /// A closed set rather than a free-form string because a typo in
        /// a model id surfaces as a download failure at first use, and
        /// embeddings are usually first used somewhere latency-sensitive.
        public enum Model: String, Sendable, CaseIterable {
            case bgeMicro
            case bgeSmall
            case bgeBase
            case gteTiny
            case miniLM
            case snowflakeXS
            case multilingualE5Small
            case nomicTextV15
            case lfm2Embedding
            case lfm2Embedding4bit
            case qwen3Embedding4bit

            // MARK: Public

            public var identifier: String {
                switch self {
                case .bgeMicro: "TaylorAI/bge-micro-v2"
                case .bgeSmall: "BAAI/bge-small-en-v1.5"
                case .bgeBase: "BAAI/bge-base-en-v1.5"
                case .gteTiny: "TaylorAI/gte-tiny"
                case .miniLM: "sentence-transformers/all-MiniLM-L6-v2"
                case .snowflakeXS: "Snowflake/snowflake-arctic-embed-xs"
                case .multilingualE5Small: "intfloat/multilingual-e5-small"
                case .nomicTextV15: "nomic-ai/nomic-embed-text-v1.5"
                case .lfm2Embedding: "LiquidAI/LFM2-Embedding-350M"
                case .lfm2Embedding4bit: "mlx-community/LFM2-Embedding-350M-4bit"
                case .qwen3Embedding4bit: "mlx-community/Qwen3-Embedding-0.6B-4bit"
                }
            }
        }

        public nonisolated var modelIdentifier: String {
            "mlx.\(self.model.identifier)"
        }

        /// Known once the model is loaded; before that, the widely-used
        /// 384 of the small BERT encoders. Callers that must size a
        /// vector store exactly should `prepare()` first.
        public nonisolated var dimensions: Int {
            self.loadedDimensions ?? 384
        }

        /// Characters, from the encoders' 512-token context at the same
        /// four-characters-per-token approximation `HeuristicTokenCounter`
        /// uses. One shared guess beats two different ones.
        public nonisolated var maxInputLength: Int {
            512 * 4
        }

        /// Download and load the weights.
        ///
        /// Separate from `init` because it can take a while on a cold
        /// cache, and a caller that wants a progress bar needs to choose
        /// when it happens.
        public func prepare(
            onProgress: @Sendable @escaping (MLXDownloadProgress) -> Void = { _ in }
        ) async throws {
            _ = try await self.container(onProgress: onProgress)
        }

        public func embed(_ texts: [String]) async throws -> [[Float]] {
            guard !texts.isEmpty else {
                return []
            }
            let container = try await container()
            let normalize = self.normalize

            let vectors = await container.perform { context in
                let encoded = texts.map {
                    context.tokenizer.encode(text: $0, addSpecialTokens: true)
                }
                let output = Self.forward(context: context, encoded: encoded)
                let pooled = context.pooling(
                    output.result,
                    mask: output.mask,
                    normalize: normalize,
                    applyLayerNorm: true
                )
                pooled.eval()
                return pooled.map { $0.asArray(Float.self) }
            }

            self.loadedDimensions = vectors.first?.count
            return vectors
        }

        // MARK: Internal

        /// Pad a ragged batch to a rectangle and run the encoder.
        ///
        /// The attention mask is the whole point: without it, padding
        /// tokens are pooled in with real ones and every short string
        /// drifts toward whatever the pad token embeds to. Kept `static`
        /// so it stays inside the container's isolation with no capture
        /// of actor state.
        static func forward(
            context: EmbedderModelContext,
            encoded: [[Int]]
        ) -> (result: EmbeddingModelOutput, mask: MLXArray) {
            let padTokenId = context.tokenizer.eosTokenId ?? 0
            let width = encoded.map(\.count).max() ?? 0
            let padded = encoded.map { tokens in
                tokens + Array(repeating: padTokenId, count: width - tokens.count)
            }
            let mask = encoded.map { tokens in
                Array(repeating: Int32(1), count: tokens.count)
                    + Array(repeating: Int32(0), count: width - tokens.count)
            }

            let inputs = MLXArray(padded.flatMap { $0.map(Int32.init) }, [padded.count, width])
            let attentionMask = MLXArray(mask.flatMap { $0 }, [mask.count, width])
            let tokenTypes = MLXArray.zeros(like: inputs)

            let output = context.model(
                inputs,
                positionIds: nil,
                tokenTypeIds: tokenTypes,
                attentionMask: attentionMask
            )
            return (output, attentionMask)
        }

        // MARK: Private

        private let model: Model
        private let downloader: MLXModelDownloader
        private let normalize: Bool
        private var loaded: EmbedderModelContainer?
        private nonisolated(unsafe) var loadedDimensions: Int?

        private func container(
            onProgress: @Sendable @escaping (MLXDownloadProgress) -> Void = { _ in }
        ) async throws -> EmbedderModelContainer {
            if let loaded {
                return loaded
            }
            let container = try await downloader.loadEmbedderContainer(
                id: self.model.identifier,
                onProgress: onProgress
            )
            self.loaded = container
            return container
        }
    }
#endif
