import Foundation

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
        .qwen25Instruct4bit,
        .gemma2Instruct4bit,
        .llama32Instruct4bit,
    ]

    /// Look up a curated entry by Hugging Face id.
    public static func entry(for id: String) -> MLXModelCapabilities? {
        self.defaults.first { $0.id == id }
    }
}

// MARK: - Curated entries

extension MLXModelCapabilities {
    /// Qwen 2.5 1.5B Instruct, 4-bit quantization. Smallest tool-
    /// capable entry in the catalog. Fits comfortably on iPhones with
    /// ≥4 GB RAM (iPhone 13 and newer).
    public static let qwen25Instruct4bit = MLXModelCapabilities(
        id: "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
        displayName: "Qwen 2.5 1.5B Instruct (4-bit)",
        family: "qwen2.5",
        approximateDiskBytes: 950_000_000, // ~900 MiB on disk
        contextWindow: 32768,
        supportsTools: true,
        recommendedRAMGigabytes: 4
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
        recommendedRAMGigabytes: 4
    )
}
