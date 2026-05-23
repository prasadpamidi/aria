#if ARIA_MLX
    import Foundation

    // MARK: - AriaMLX

    /// Module-level identity for the `AriaMLX` library.
    ///
    /// `AriaMLX` adds an `LLMProvider` backed by Apple MLX
    /// (`mlx-swift-lm`) plus a curated model catalog, Hugging Face hub
    /// downloader, and disk manager so consumers can let users pick,
    /// fetch, and clean up models on device.
    public enum AriaMLX {
        public static let version = "0.0.1-alpha.1"
    }
#endif
