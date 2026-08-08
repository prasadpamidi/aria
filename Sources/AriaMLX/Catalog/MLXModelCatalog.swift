#if ARIA_MLX
    import Foundation
    import MLXLMCommon

    // MARK: - MLXModelCatalog

    /// Curated set of MLX models the sample app surfaces by default.
    ///
    /// Each entry was hand-checked for tool-call template support and
    /// approximate on-disk size as of the matching `mlx-swift-lm`
    /// release. Consumers can extend the catalog with their own entries
    /// or use `ChatTemplateInspector` to detect capabilities at runtime
    /// for user-added models.
    public enum MLXModelCatalog {
        /// Default models the sample app shows in its model picker.
        /// Ordered roughly by RAM footprint.
        public static let defaults: [MLXModelCapabilities] = [
            .qwen35MLX0_8B4bit,
            .lfm25_350M6bit,
            .lfm25VL450M6bit,
            .qwen25Instruct1_5B4bit,
            .lfm25Instruct1_2B4bit,
            .lfm25Thinking1_2B4bit,
            .gemma2Instruct4bit,
            .lfm25VL1_6B4bit,
            .llama32Instruct4bit,
            .qwen35MLX4B4bit,
            .gemma4E2BInstruct4bit,
            .gemma4E4BInstruct4bit,
            .qwen35MLX9B4bit,
        ]

        /// Look up a curated entry by Hugging Face id.
        public static func entry(for id: String) -> MLXModelCapabilities? {
            self.defaults.first { $0.id == id }
        }
    }

    // MARK: - Curated entries

    extension MLXModelCapabilities {
        /// Qwen 3.5 0.8B VL (vision + text, *non-reasoning*), 4-bit
        /// quantization. Smallest Qwen 3.5 — fast on any A-series
        /// device. ~500 MB on disk; needs ~2 GB RAM. Same Hermes-
        /// style tool template as its larger siblings, but unlike
        /// the 4B/9B variants this one *doesn't* emit
        /// `<think>…</think>` reasoning blocks — it streams the
        /// visible answer directly. Setting `supportsReasoning: false`
        /// keeps `ChatScreen.activeModelIsReasoning` from routing
        /// the answer into the Thinking pill while the stream is
        /// in flight.
        public static let qwen35MLX0_8B4bit = MLXModelCapabilities(
            id: "mlx-community/Qwen3.5-0.8B-MLX-4bit",
            displayName: "Qwen 3.5 0.8B (4-bit)",
            family: "qwen3.5-vl",
            kind: .vision,
            approximateDiskBytes: 500_000_000, // ~500 MB on disk
            contextWindow: 131_072,
            supportsTools: true,
            supportsVision: true,
            supportsReasoning: false,
            reliability: .low,
            recommendedRAMGigabytes: 2
        )

        /// Qwen 2.5 1.5B Instruct, 4-bit quantization. Text-only,
        /// non-reasoning — `family: "qwen2.5"` doesn't match the
        /// `qwen3*` reasoning prefix, so the chat treats it as a
        /// straight instruct model (no thinking pill). Tool calls
        /// still flow through `QwenToolCallStreamParser` via the
        /// shared `qwen` prefix check. ~1 GB on disk; ~3 GB RAM.
        /// Good middle ground between the 0.8B Qwen 3.5 and the
        /// 2 B+ Gemma / Llama family entries.
        public static let qwen25Instruct1_5B4bit = MLXModelCapabilities(
            id: "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
            displayName: "Qwen 2.5 1.5B Instruct (4-bit)",
            family: "qwen2.5",
            approximateDiskBytes: 1_000_000_000, // ~1.0 GiB
            contextWindow: 32768,
            supportsTools: true,
            reliability: .low,
            recommendedRAMGigabytes: 3
        )

        /// Qwen 3.5 4B (vision + text), 4-bit quantization. Smallest
        /// vision-capable Qwen 3.5 variant. ~2.4 GB on disk; needs
        /// ~6 GB RAM (iPhone 15+). Uses mlx-vlm under the hood, so
        /// images flow through the same Hermes-style tool-calling
        /// template as the text-only Qwen line.
        public static let qwen35MLX4B4bit = MLXModelCapabilities(
            id: "mlx-community/Qwen3.5-4B-MLX-4bit",
            displayName: "Qwen 3.5 4B (4-bit)",
            family: "qwen3.5-vl",
            kind: .vision,
            approximateDiskBytes: 2_400_000_000, // ~2.4 GiB on disk
            contextWindow: 131_072,
            supportsTools: true,
            supportsVision: true,
            supportsReasoning: true,
            reliability: .medium,
            recommendedRAMGigabytes: 6
            // `toolCallFormat: nil` — `mlx-swift-lm`'s `.json`
            // parser misses Qwen 3.5 edge cases. `MLXProvider`
            // routes raw `.chunk` text through
            // `QwenToolCallStreamParser` instead.
        )

        /// Qwen 3.5 9B (vision + text), 4-bit quantization.
        /// Higher-quality replies than the 4B; needs ~12 GB RAM
        /// (iPhone 17 Pro / M-series only). ~5 GB on disk.
        public static let qwen35MLX9B4bit = MLXModelCapabilities(
            id: "mlx-community/Qwen3.5-9B-MLX-4bit",
            displayName: "Qwen 3.5 9B (4-bit)",
            family: "qwen3.5-vl",
            kind: .vision,
            approximateDiskBytes: 5_000_000_000, // ~5.0 GiB on disk
            contextWindow: 131_072,
            supportsTools: true,
            supportsVision: true,
            supportsReasoning: true,
            reliability: .high,
            recommendedRAMGigabytes: 12
            // See qwen35MLX4B4bit — we own Qwen tool parsing.
        )

        /// Llama 3.2 3B Instruct, 4-bit quantization. Higher-quality
        /// replies than Qwen 1.5B. Recommend A17 Pro / A18 / M-series.
        public static let llama32Instruct4bit = MLXModelCapabilities(
            id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            displayName: "Llama 3.2 3B Instruct (4-bit)",
            family: "llama-3.2",
            approximateDiskBytes: 1_900_000_000, // ~1.8 GiB
            contextWindow: 131_072,
            supportsTools: true,
            reliability: .medium,
            recommendedRAMGigabytes: 6
        )

        /// Gemma 2 2B Instruct, 4-bit quantization. Google's small
        /// instruct model. Native function-call template.
        public static let gemma2Instruct4bit = MLXModelCapabilities(
            id: "mlx-community/gemma-2-2b-it-4bit",
            displayName: "Gemma 2 2B Instruct (4-bit)",
            family: "gemma-2",
            approximateDiskBytes: 1_500_000_000, // ~1.4 GiB
            contextWindow: 8192,
            supportsTools: true,
            reliability: .medium,
            recommendedRAMGigabytes: 4,
            // model_type "gemma2" isn't covered by ToolCallFormat.infer
            // (only exact "gemma" matches); template emits the
            // <start_function_call>call:NAME{...}<end_function_call>
            // form that GemmaFunctionParser handles.
            toolCallFormat: .gemma
        )

        /// Google Gemma 4 e2b Instruct, 4-bit quantization. Smallest
        /// of the Gemma 4 family — 1B effective params, vision +
        /// language. Pre-registered as `gemma4_E2B_it_4bit` in
        /// `MLXVLM.VLMRegistry`. Apache 2.0. Ships with a tool-
        /// calling chat template that emits
        /// `<|tool_call>call:NAME{...}<tool_call|>`. mlx-swift-lm
        /// has no built-in parser for that format yet, so
        /// `toolCallFormat` stays `nil` and `MLXProvider` routes the
        /// raw text through a family-specific stream parser (see
        /// `Gemma4ToolCallStreamParser`) before yielding agent
        /// events.
        public static let gemma4E2BInstruct4bit = MLXModelCapabilities(
            id: "mlx-community/gemma-4-e2b-it-4bit",
            displayName: "Gemma 4 e2b Instruct (4-bit)",
            family: "gemma-4",
            kind: .vision,
            approximateDiskBytes: 3_600_000_000, // ~3.58 GiB on disk
            contextWindow: 8192,
            supportsTools: true,
            supportsVision: true,
            reliability: .low, // 1 B effective params
            recommendedRAMGigabytes: 6
        )

        /// Google Gemma 4 e4b Instruct, 4-bit quantization. 2B
        /// effective params, vision + language. Recommend
        /// A17 Pro / A18 / M-series for usable inference speed.
        /// Same custom tool-call format as e2b — handled via
        /// `Gemma4ToolCallStreamParser`.
        public static let gemma4E4BInstruct4bit = MLXModelCapabilities(
            id: "mlx-community/gemma-4-e4b-it-4bit",
            displayName: "Gemma 4 e4b Instruct (4-bit)",
            family: "gemma-4",
            kind: .vision,
            approximateDiskBytes: 5_300_000_000, // ~5.22 GiB on disk
            contextWindow: 8192,
            supportsTools: true,
            supportsVision: true,
            reliability: .medium, // 2 B effective params
            recommendedRAMGigabytes: 8
        )

        // MARK: LFM2.5 (Liquid AI)

        //
        // Hybrid convolution + attention models. The text variants
        // load as `model_type: "lfm2"` via `MLXLLM.LLMModelFactory`;
        // the VL variants as `"lfm2_vl"` via `MLXVLM.VLMModelFactory`.
        // Both are already registered in `mlx-swift-lm`, so these
        // entries are pure metadata — no provider-side work needed.
        //
        // All five emit pythonic tool calls wrapped in the
        // `<|tool_call_start|>` / `<|tool_call_end|>` special tokens,
        // and `toolCallFormat` is deliberately left `nil`.
        //
        // The template emits a *list* inside one tag pair —
        // `[get_weather(city="Paris"), current_time()]` — which
        // `mlx-swift-lm`'s `ToolCallParser` cannot represent, since
        // `parse` returns a single optional `ToolCall`. Given two
        // calls it yields one corrupt call rather than dropping the
        // second, so `MLXProvider` routes raw chunks through
        // `LFM2ToolCallStreamParser` instead. Setting a format here
        // would have the library parse in parallel and duplicate the
        // calls.
        //
        // `family: "lfm2.5"` deliberately matches none of the
        // `usesQwenToolFormat` / `usesLlama3ToolFormat` /
        // `usesGemma4ToolFormat` prefixes, so `MLXProvider` leaves
        // parsing to `mlx-swift-lm` rather than routing raw chunks
        // through an Aria-side stream parser.
        //
        // Every variant advertises a 128k context window in
        // `config.json`. That is the model's trained maximum, not a
        // promise about KV-cache headroom on a phone — the same
        // caveat that already applies to the 131k Qwen entries.

        /// Liquid AI LFM2.5 350M, 6-bit quantization. Smallest entry
        /// in the catalog at ~364 MiB. mlx-community never published
        /// a plain 4-bit at this size, and 4-bit on a sub-500M model
        /// costs more quality than the ~90 MiB it would save, so
        /// 6-bit is the floor here.
        public static let lfm25_350M6bit = MLXModelCapabilities(
            id: "mlx-community/LFM2.5-350M-6bit",
            displayName: "LFM2.5 350M (6-bit)",
            family: "lfm2.5",
            approximateDiskBytes: 381_000_000, // ~364 MiB on disk
            contextWindow: 128_000,
            supportsTools: true,
            reliability: .low,
            recommendedRAMGigabytes: 2
        )

        /// Liquid AI LFM2.5 VL 450M, 6-bit quantization. Smallest
        /// vision-capable entry in the catalog — ~450 MiB, which
        /// undercuts the Qwen 3.5 0.8B by a comfortable margin.
        /// Like the 350M, no plain 4-bit exists upstream.
        ///
        /// The `requiresOpenAIToolShapeOverride: true` is *not*
        /// boilerplate. Alone among the five LFM2.5 entries, the
        /// chat template shipped in this quantized repo renders
        /// prior tool round-trips through a `render_tool_calls`
        /// macro reading `message.tool_calls`, so `MLXProvider` has
        /// to emit OpenAI-shaped messages or the assistant's tool
        /// call vanishes from history between agent turns. Its four
        /// siblings render plain `content` and must NOT get that
        /// treatment. Re-verify if this entry is ever repointed at a
        /// freshly converted repo.
        public static let lfm25VL450M6bit = MLXModelCapabilities(
            id: "mlx-community/LFM2.5-VL-450M-6bit",
            displayName: "LFM2.5 VL 450M (6-bit)",
            family: "lfm2.5",
            kind: .vision,
            approximateDiskBytes: 471_000_000, // ~450 MiB on disk
            contextWindow: 128_000,
            supportsTools: true,
            supportsVision: true,
            reliability: .low,
            recommendedRAMGigabytes: 2,
            requiresOpenAIToolShapeOverride: true
        )

        /// Liquid AI LFM2.5 1.2B Instruct, 4-bit quantization. The
        /// mainstream pick of the family — ~633 MiB, undercutting
        /// Qwen 2.5 1.5B by a third at comparable quality.
        /// Non-reasoning: streams its answer directly, so
        /// `supportsReasoning` stays `false` and the Thinking pill
        /// never fires.
        public static let lfm25Instruct1_2B4bit = MLXModelCapabilities(
            id: "mlx-community/LFM2.5-1.2B-Instruct-4bit",
            displayName: "LFM2.5 1.2B Instruct (4-bit)",
            family: "lfm2.5",
            approximateDiskBytes: 663_000_000, // ~633 MiB on disk
            contextWindow: 128_000,
            supportsTools: true,
            reliability: .low,
            recommendedRAMGigabytes: 3
        )

        /// Liquid AI LFM2.5 1.2B Thinking, 4-bit quantization. Same
        /// size and architecture as the Instruct variant, tuned to
        /// emit a `<think>…</think>` block before the visible reply.
        /// `<think>` / `</think>` are real special tokens in this
        /// tokenizer, so the existing reasoning plumbing — the chat
        /// Thinking pill and `VoiceController`'s TTS strip regex —
        /// works unchanged.
        ///
        /// This is the only LFM2.5 entry with
        /// `supportsReasoning: true`. Several siblings ship
        /// templates that *handle* a `thinking` field when rendering
        /// past turns, but handling one is not the same as emitting
        /// one; flagging them would flash the Thinking pill on every
        /// turn for models that stream answers directly.
        public static let lfm25Thinking1_2B4bit = MLXModelCapabilities(
            id: "mlx-community/LFM2.5-1.2B-Thinking-4bit",
            displayName: "LFM2.5 1.2B Thinking (4-bit)",
            family: "lfm2.5",
            approximateDiskBytes: 663_000_000, // ~633 MiB on disk
            contextWindow: 128_000,
            supportsTools: true,
            supportsReasoning: true,
            reliability: .low,
            recommendedRAMGigabytes: 3
        )

        /// Liquid AI LFM2.5 VL 1.6B, 4-bit quantization. The
        /// higher-quality vision option — ~1.4 GiB, still well under
        /// the 2.4 GiB Qwen 3.5 4B. Pre-registered as
        /// `lfm2_5_vl_1_6B_4bit` in `MLXVLM.VLMRegistry`.
        public static let lfm25VL1_6B4bit = MLXModelCapabilities(
            id: "mlx-community/LFM2.5-VL-1.6B-4bit",
            displayName: "LFM2.5 VL 1.6B (4-bit)",
            family: "lfm2.5",
            kind: .vision,
            approximateDiskBytes: 1_496_000_000, // ~1.39 GiB on disk
            contextWindow: 128_000,
            supportsTools: true,
            supportsVision: true,
            reliability: .low,
            recommendedRAMGigabytes: 4
        )
    }
#endif
