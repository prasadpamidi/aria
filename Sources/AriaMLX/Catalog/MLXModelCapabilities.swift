#if canImport(MLXLMCommon)
    import Foundation
    import MLXLMCommon

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
            recommendedRAMGigabytes: Int = 4,
            toolCallFormat: ToolCallFormat? = nil
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
            self.toolCallFormat = toolCallFormat
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

        /// Override `mlx-swift-lm`'s tool-call format inference. The
        /// library only auto-detects a handful of `model_type`
        /// strings — Qwen 2.5 (`qwen2`), Qwen 2.5 VL
        /// (`qwen2_5_vl`), Gemma 2 (`gemma2`), and Gemma 4 (`gemma4`)
        /// all return `nil` from `ToolCallFormat.infer`. Without an
        /// override, tool-call output gets emitted as plain text and
        /// the agent never executes anything. Set this to the format
        /// the model's chat template actually uses (e.g. `.json` for
        /// Hermes-style `<tool_call>{...}</tool_call>`). For models
        /// whose format isn't covered by any built-in parser
        /// (Gemma 4), leave `nil` and let the AriaMLX-side stream
        /// parser handle it via family-based routing.
        public let toolCallFormat: ToolCallFormat?

        /// `true` for models in the Gemma 4 family. Their chat
        /// template emits a tool-call format
        /// (`<|tool_call>call:NAME{...}<tool_call|>`) that no
        /// `mlx-swift-lm` parser handles, so `MLXProvider` routes
        /// raw `.chunk` text through `Gemma4ToolCallStreamParser`
        /// instead of relying on `Generation.toolCall` events.
        public var usesGemma4ToolFormat: Bool {
            self.family == "gemma-4"
        }
    }
#endif
