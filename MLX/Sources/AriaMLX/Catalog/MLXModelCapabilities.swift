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

        /// Hugging Face hub id, e.g. `"mlx-community/Qwen3.5-4B-MLX-4bit"`.
        public let id: String

        /// User-facing label.
        public let displayName: String

        /// Model family for capability inference fallbacks
        /// (e.g. "qwen3.5-vl", "llama-3.2", "gemma-2").
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
        /// strings — Qwen 3.5 VL (`qwen3`), Gemma 2 (`gemma2`),
        /// and Gemma 4 (`gemma4`)
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

        /// `true` for the Llama 3.x family (3, 3.1, 3.2, …). Their
        /// chat template wraps tool calls in
        /// `<|python_tag|>{...}<|eom_id|>`, which `mlx-swift-lm`'s
        /// built-in `ToolCallProcessor` doesn't fully parse — the
        /// raw control tokens leak as visible text.
        /// `MLXProvider` routes raw `.chunk` text through
        /// `Llama3ToolCallStreamParser` for this family.
        public var usesLlama3ToolFormat: Bool {
            self.family.hasPrefix("llama-3")
        }

        /// `true` for the Qwen family (2.5 / 3.x / 3.5, both text
        /// and VL variants). Tool calls are wrapped in Hermes-style
        /// `<tool_call>{json}</tool_call>` envelopes.
        /// `mlx-swift-lm`'s `.json` `ToolCallProcessor` targets the
        /// same shape but has edge cases the Qwen 3.5 jinja
        /// template trips (whitespace, escaped braces, mixed
        /// XML/JSON drift in long contexts). Owning the parsing
        /// ourselves via `QwenToolCallStreamParser` is more
        /// reliable; catalog entries set `toolCallFormat: nil` so
        /// `mlx-swift-lm` doesn't try to parse in parallel.
        public var usesQwenToolFormat: Bool {
            self.family.hasPrefix("qwen")
        }

        /// `true` when the model's chat template requires the
        /// OpenAI Chat Completions message shape
        /// (`assistant.tool_calls` + `role:tool` with
        /// `tool_call_id`) to render prior tool round-trips.
        /// `mlx-swift-lm`'s built-in `MessageGenerator`s drop
        /// `tool_calls` on the floor, so `MLXProvider` has to bypass
        /// them and emit raw `[MLXLMCommon.Message]` dicts for these
        /// families.
        ///
        /// Why Llama 3 needs this too: even though Llama 3 emits
        /// tool calls via `<|python_tag|>` (captured by
        /// `Llama3ToolCallStreamParser`), the *next* agent loop
        /// needs to feed the tool result back. Without the OpenAI
        /// shape, the assistant message that triggered the tool
        /// loses its `tool_calls` field, and the tool result loses
        /// its `tool_call_id` — so Llama never realizes the tool
        /// was called or what it returned, and can't produce a
        /// follow-up reply that reads the result.
        public var requiresOpenAIToolShape: Bool {
            self.usesGemma4ToolFormat
                || self.usesLlama3ToolFormat
                || self.family == "qwen3.5-vl"
        }
    }
#endif
