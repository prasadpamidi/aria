#if canImport(Foundation) && (os(iOS) || os(macOS) || os(watchOS) || os(tvOS) || os(visionOS))

    import Aria
    import Foundation

    /// AriaApple — Apple-platform implementations of Aria's protocols.
    ///
    /// This module contains the concrete implementations that bridge Aria's
    /// platform-agnostic protocols to Apple frameworks:
    ///
    /// - `FoundationModelsProvider` (LLMProvider over Apple FoundationModels)
    /// - `MLXProvider` (LLMProvider over MLX)
    /// - `CoreMLProvider` (LLMProvider over Core ML)
    /// - `NLEmbeddingEmbedder`, `CoreMLEmbedder`, `MLXEmbedder` (Embedder)
    /// - `SwiftDataChatHistory`, `SwiftDataCheckpointer` (memory)
    /// - `SQLiteVecVectorStore` (VectorStore)
    /// - `OSLogObserver`, `OSLogMiddleware` (observability)
    ///
    /// Implementation is pending. See `docs/architecture.md` for the target design.
    public enum AriaApple {
        /// The current version. Matches `Aria.version` in lockstep.
        public static let version = Aria.version
    }

#endif
