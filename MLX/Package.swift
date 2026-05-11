// swift-tools-version: 6.1
//
// AriaMLX — MLX-backed LLMProvider + model management for Aria.
//
// Lives in its own SwiftPM package so consumers that only want
// `Aria` + `AriaApple` (e.g. iOS apps using FoundationModels via
// the on-device path) don't pay the cost of resolving
// `mlx-swift-lm` and its transitive deps — most importantly
// `swift-transformers`, which has version pins incompatible with
// other Apple ecosystem packages (WhisperKit, etc.).

import PackageDescription

let package = Package(
    name: "AriaMLX",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "AriaMLX", targets: ["AriaMLX"]),
    ],
    dependencies: [
        // Re-use the parent Aria package for the core types
        // (LLMProvider, Agent, JSONSchema, etc.) and AriaApple
        // (FoundationModels bridge) when needed.
        .package(path: ".."),
        // MLX on-device LLM runtime + model download. Apple-Silicon-only.
        // `mlx-swift-lm` 3.x split out the LM libraries and requires
        // consumers to wire up an external downloader + tokenizer loader;
        // we use DePasqualeOrg's adapter packages
        // (`swift-huggingface-mlx` for the HF Hub downloader,
        // `swift-transformers-mlx` for tokenizer loading).
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "3.31.3"),
        .package(url: "https://github.com/DePasqualeOrg/swift-huggingface-mlx.git", from: "0.2.0"),
        .package(url: "https://github.com/DePasqualeOrg/swift-transformers-mlx.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "AriaMLX",
            dependencies: [
                .product(name: "Aria", package: "Aria"),
                // mlx-swift's C++ backend needs Apple's Accelerate /
                // Metal headers — it can't build on Linux. Gate every
                // MLX product on Apple platforms; AriaMLX's own
                // sources are wrapped in `#if canImport(MLXLMCommon)`
                // so the target builds (empty) elsewhere.
                .product(
                    name: "MLXLLM",
                    package: "mlx-swift-lm",
                    condition: .when(platforms: [.iOS, .macOS, .visionOS])
                ),
                .product(
                    name: "MLXVLM",
                    package: "mlx-swift-lm",
                    condition: .when(platforms: [.iOS, .macOS, .visionOS])
                ),
                .product(
                    name: "MLXLMCommon",
                    package: "mlx-swift-lm",
                    condition: .when(platforms: [.iOS, .macOS, .visionOS])
                ),
                .product(
                    name: "MLXLMHuggingFace",
                    package: "swift-huggingface-mlx",
                    condition: .when(platforms: [.iOS, .macOS, .visionOS])
                ),
                .product(
                    name: "MLXLMTransformers",
                    package: "swift-transformers-mlx",
                    condition: .when(platforms: [.iOS, .macOS, .visionOS])
                ),
            ],
            path: "Sources/AriaMLX"
        ),

        .testTarget(
            name: "AriaMLXTests",
            dependencies: [
                "AriaMLX",
                .product(name: "Aria", package: "Aria"),
                .product(name: "AriaTesting", package: "Aria"),
            ],
            path: "Tests/AriaMLXTests"
        ),
    ]
)
