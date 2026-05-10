#if canImport(MLXLMCommon)
    import Foundation

    // MARK: - MLXModelCapabilities

    /// What an MLX model can do, plus enough metadata to drive UI
    /// (download status, disk-size estimates, tool advertisement).
    ///
    /// Capabilities are sourced two ways:
    /// 1. Curated entries shipped in `MLXModelCatalog` for known-good
    ///    models — these have hand-checked tool support flags.
    /// 2. Runtime detection via `ChatTemplateInspector` for user-added
    ///    models — chat-template Jinja inspection plus
    ///    `config.json` / `model_type` fallbacks.
    /// Whether a model is text-only or vision-capable. Used by the
    /// downloader and provider to pick `LLMModelFactory` vs
    /// `VLMModelFactory` from `mlx-swift-lm`.
    public enum MLXModelKind: String, Sendable, Codable {
        case textOnly
        case vision
    }

    public struct MLXModelCapabilities: Sendable, Hashable, Codable {
        // MARK: Lifecycle

        public init(
            id: String,
            displayName: String,
            family: String,
            kind: MLXModelKind = .textOnly,
            approximateDiskBytes: Int64,
            contextWindow: Int,
            supportsTools: Bool,
            supportsVision: Bool = false,
            recommendedRAMGigabytes: Int = 4
        ) {
            self.id = id
            self.displayName = displayName
            self.family = family
            self.kind = kind
            self.approximateDiskBytes = approximateDiskBytes
            self.contextWindow = contextWindow
            self.supportsTools = supportsTools
            self.supportsVision = supportsVision
            self.recommendedRAMGigabytes = recommendedRAMGigabytes
        }

        // MARK: Public

        /// Hugging Face hub id, e.g. `"mlx-community/Qwen2.5-1.5B-Instruct-4bit"`.
        public let id: String

        /// User-facing label.
        public let displayName: String

        /// Model family for capability inference fallbacks
        /// (e.g. "qwen2.5", "llama-3.2", "gemma-2").
        public let family: String

        /// Whether the model expects image inputs alongside text.
        /// Drives the factory pick (LLM vs VLM) at load time.
        public let kind: MLXModelKind

        /// Rough on-disk size in bytes — used to render download UI
        /// hints. The real size after download may differ; the disk
        /// manager reports authoritative values.
        public let approximateDiskBytes: Int64

        /// Maximum context length in tokens advertised by the model's
        /// `config.json`.
        public let contextWindow: Int

        /// Whether the model's chat template understands `tools` and
        /// emits structured tool calls. When `false`, the provider
        /// drops any `executableTools` it's handed and the agent runs
        /// text-only.
        public let supportsTools: Bool

        /// Whether the model accepts image inputs. Aria's current
        /// `Message` shape is text-only, so vision-capable models still
        /// run text-only here; the flag is surfaced for UI.
        public let supportsVision: Bool

        /// Suggested minimum device RAM in gigabytes for comfortable
        /// inference of this model. Used by the sample app to grey out
        /// models that exceed device constraints.
        public let recommendedRAMGigabytes: Int
    }
#endif
