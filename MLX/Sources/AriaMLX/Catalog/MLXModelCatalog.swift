#if canImport(MLXLMCommon)
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
            .gemma2Instruct4bit,
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
            recommendedRAMGigabytes: 8
        )
    }
#endif
