// swift-tools-version: 6.1
//
// Aria — Composable on-device agent runtime for Apple platforms.
// See docs/architecture.md for the SDK overview.
//
// **Heavy dependencies are trait-gated** (SE-0480, Swift 6.1+):
//
//   * `MLX` trait pulls in `mlx-swift-lm` + adapter packages so
//     `AriaMLX` can vend MLX-backed LLMProviders. Consumers that
//     only want FoundationModels via `AriaApple` should leave this
//     trait off so SPM doesn't resolve mlx-swift's transitive graph.
//   * `VoiceKokoro` trait pulls in the 3theories/kokoro-ios fork +
//     `mlx-swift` + `MLXUtilsLibrary` so `AriaVoiceKokoro` can vend
//     an on-device Kokoro TTS provider. Off by default.
//
// Enable in a consumer's Package.swift:
//
// ```swift
// .package(url: ".../aria.git", from: "0.1.0", traits: ["MLX", "VoiceKokoro"])
// ```
//
// Or in an Xcode project's Package Dependency dialog, tick the
// `MLX` and / or `VoiceKokoro` checkboxes when adding aria.

import PackageDescription

let package = Package(
    name: "Aria",
    platforms: [
        // iOS 18 / macOS 15 floor is set by `kokoro-ios` (used by
        // `AriaVoiceKokoro` under the `VoiceKokoro` trait) which
        // ships with a tighter platform floor than the rest of Aria
        // strictly needs. SPM enforces the strictest required-by-
        // any-target floor at the package level, so consumers that
        // don't enable the `VoiceKokoro` trait still inherit this
        // floor. If iOS 17 / macOS 14 support is critical for a
        // consumer, fork aria and split AriaVoiceKokoro back into
        // its own package.
        .iOS(.v18),
        .macOS(.v15),
        .watchOS(.v10),
        .tvOS(.v17),
        .visionOS(.v1),
    ],
    products: [
        // The platform-agnostic core. Builds on Linux. No Apple-only imports.
        .library(name: "Aria", targets: ["Aria"]),

        // Mocks, fixtures, and test helpers. Cross-platform.
        .library(name: "AriaTesting", targets: ["AriaTesting"]),

        // Apple system-framework implementations: FoundationModels,
        // NLEmbedding, GRDB-backed memory, OSLog.
        .library(name: "AriaApple", targets: ["AriaApple"]),

        // Cross-platform tool implementations.
        .library(name: "AriaTools", targets: ["AriaTools"]),

        // Apple-only JavaScript tool plugin runtime. Loads
        // `.aria-tool` JSON bundles (manifest + embedded JS) and
        // vends them as `AnyTool`s the agent can call. Sandboxed
        // per-tool `JSContext`s; capabilities (HTTP, JSON, clipboard,
        // share, notify, storage) are gated by per-tool manifest
        // declarations enforced at bridge-construction time.
        .library(name: "AriaToolsJS", targets: ["AriaToolsJS"]),

        // Apple-platform voice: STT (Speech.framework), TTS protocol +
        // AVSpeechSynthesizer-backed default impl, and the voice-mode
        // state machine. Always available; the heavier Kokoro TTS
        // implementation ships behind the `VoiceKokoro` trait.
        .library(name: "AriaVoice", targets: ["AriaVoice"]),

        // MLX-backed LLMProvider + model download/management for Aria.
        // Apple-Silicon only. The target compiles empty when the `MLX`
        // trait is off, so importing it on a consumer that didn't enable
        // the trait is a no-op rather than a hard error.
        .library(name: "AriaMLX", targets: ["AriaMLX"]),

        // On-device Kokoro 82M TTS provider for AriaVoice. Apple-Silicon
        // only (iOS 18+, macOS 15+). The target compiles empty when the
        // `VoiceKokoro` trait is off; consumers that don't need Kokoro
        // keep using the default AVSpeechSynthesizer TTS in AriaVoice.
        .library(name: "AriaVoiceKokoro", targets: ["AriaVoiceKokoro"]),

        // Workflow runtime — Codable workflow model + GRDB
        // persistence + compile-to-`Aria.StateGraph` engine + the
        // `CapabilityBroker` that mediates native + JS capability
        // calls. Apple-only because the native capabilities
        // (Secrets, HealthKit, EventKit, CoreLocation, Files) lean
        // on iOS frameworks; the cross-platform pieces use
        // `#if canImport(…)` guards so the target compiles empty
        // on Linux.
        .library(name: "WorkflowKit", targets: ["WorkflowKit"]),
    ],
    traits: [
        // Both traits are OFF by default so consumers that don't
        // need MLX or Kokoro (Niora, server-only Linux consumers,
        // etc.) don't pay any resolution / link cost for them.
        //
        // Apple-platform consumers that want the full SDK enable
        // both explicitly:
        //
        //   .package(url: ".../aria.git", from: "0.0.1",
        //            traits: ["MLX", "VoiceKokoro"])
        //
        // Xcode consumers tick the trait checkboxes in the Package
        // Dependencies dialog. The trait flag is also stored as
        // `traits = (MLX, VoiceKokoro)` on the
        // XCRemoteSwiftPackageReference in the pbxproj.

        // Pulls in `mlx-swift-lm` 3.x + tokenizer / HF-hub adapters.
        // Apple-Silicon-only at the dep level; the AriaMLX source
        // additionally uses `#if canImport(MLXLMCommon)` so the
        // target degrades gracefully on platforms where mlx-swift's
        // C++ backend can't build (Linux).
        .trait(name: "MLX", description: "Enable MLX-backed on-device LLMProviders (mlx-swift-lm)."),

        // Pulls in the 3theories/kokoro-ios fork + a separate
        // `mlx-swift` pin compatible with kokoro-ios. Independent
        // of the `MLX` trait — Kokoro uses mlx-swift directly,
        // not mlx-swift-lm.
        .trait(name: "VoiceKokoro", description: "Enable on-device Kokoro 82M TTS provider (kokoro-ios)."),
    ],
    dependencies: [
        // MARK: - Always-on dependencies

        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
        // OpenTelemetry-compatible tracing + metrics. The libraries are
        // protocol-only and ship with no-op defaults; consumers wire up
        // an exporter (swift-otel, etc.) at process start to send data
        // anywhere. Aria emits OTel GenAI semantic-convention attributes.
        .package(url: "https://github.com/apple/swift-distributed-tracing.git", from: "1.1.2"),
        // Direct dep on swift-service-context so we can explicitly
        // surface `ServiceContextModule` as an Aria-target link
        // dependency — needed for Xcode's dynamic-framework wrapping
        // of Aria during `xcodebuild test` (see comment in the Aria
        // target's dependencies list).
        .package(url: "https://github.com/apple/swift-service-context.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-metrics.git", from: "2.5.0"),
        // Persistent memory (chat history + checkpointer) for AriaApple.
        // Apple-only — `Aria` core never imports it.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),

        // MARK: - MLX / VoiceKokoro dependencies

        //
        // **Resolution-time cost trade-off**: SPM's `traits:` argument
        // on `.package(...)` forwards traits to an upstream package
        // (which would need to declare them); it does NOT gate
        // whether the upstream is resolved. To skip resolution
        // entirely you need separate repos.
        //
        // We keep MLX and Kokoro deps unconditionally listed so a
        // unified package stays viable, then gate them at the
        // **target-dependency** layer via `condition: .when(traits:)`.
        // Consumers who don't enable the `MLX` / `VoiceKokoro`
        // traits still see these in `Package.resolved`, but neither
        // the AriaMLX nor the AriaVoiceKokoro target compiles their
        // heavy bodies in (sources are guarded by `#if
        // canImport(MLXLMCommon)` / `#if canImport(KokoroSwift)`).
        //
        // `mlx-swift-lm` 3.x split out the LM libraries and requires
        // consumers to wire up an external downloader + tokenizer loader;
        // we use DePasqualeOrg's adapter packages (`swift-huggingface-mlx`
        // for the HF Hub downloader, `swift-transformers-mlx` for
        // tokenizer loading).
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "3.31.3"),
        .package(url: "https://github.com/DePasqualeOrg/swift-huggingface-mlx.git", from: "0.2.0"),
        // Pinned to a tagged release so downstream consumers (Avyra,
        // Niora, etc.) can pin aria itself by version. SPM rejects a
        // stable-version pin on a package whose own deps are
        // branch-tracked.
        .package(url: "https://github.com/DePasqualeOrg/swift-transformers-mlx.git", from: "0.2.0"),

        // Kokoro + Misaki are fetched from the 3theories forks
        // (https://github.com/3theories/kokoro-ios and .../MisakiSwift),
        // which carry the relaxed `mlx-swift` pin (`0.30.0..<1.0.0`)
        // needed to coexist with AriaMLX's `mlx-swift-lm` 0.31.x pin,
        // plus a resource-bundle-flattening patch for iOS codesign
        // compatibility.
        // Pinned to a tagged release of the 3theories fork so
        // downstream consumers can pin aria by version. The fork's
        // own deps (MisakiSwift, mlx-swift) are now all
        // version-pinned to satisfy SPM's stable-version rule.
        .package(url: "https://github.com/3theories/kokoro-ios.git", from: "0.0.1"),
        // mlx-swift is shared by both kokoro-ios and AriaVoiceKokoro's
        // own `import MLX` for `MLXArray`. Independent of mlx-swift-lm.
        .package(url: "https://github.com/ml-explore/mlx-swift", "0.30.0"..<"1.0.0"),
        .package(url: "https://github.com/mlalma/MLXUtilsLibrary.git", "0.0.6"..<"1.0.0"),
    ],
    targets: [
        // MARK: - Library targets

        .target(
            name: "Aria",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Collections", package: "swift-collections"),
                .product(name: "Tracing", package: "swift-distributed-tracing"),
                // `withSpan(_:ofKind:_:)` from Tracing internally reads
                // `ServiceContext.current` (a TaskLocal stored in the
                // ServiceContextModule product). When Aria is built as a
                // dynamic framework (e.g. by Xcode under `xcodebuild test`),
                // the framework's link spec must list ServiceContextModule
                // explicitly — Tracing's transitive declaration isn't
                // honored by the framework wrapper, leading to undefined
                // `ServiceContext.{current,topLevel}` symbols. Listing it
                // here is a no-op at the static-library link layer but
                // unblocks the test framework build.
                .product(name: "ServiceContextModule", package: "swift-service-context"),
                .product(name: "Metrics", package: "swift-metrics"),
            ],
            path: "Sources/Aria"
        ),

        .target(
            name: "AriaTesting",
            dependencies: ["Aria"],
            path: "Sources/AriaTesting"
        ),

        .target(
            name: "AriaApple",
            dependencies: [
                "Aria",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/AriaApple"
        ),

        .target(
            name: "AriaTools",
            dependencies: ["Aria"],
            path: "Sources/AriaTools"
        ),

        // AriaToolsJS depends on AriaTools so JS authors get access
        // to the same primitives (HTTP, JSON, calculator, regex) via
        // the `Aria.*` bridge object that Swift authors use natively.
        // JavaScriptCore is Apple-only; sources are guarded with
        // `#if canImport(JavaScriptCore)` so the target compiles
        // empty on Linux.
        .target(
            name: "AriaToolsJS",
            dependencies: ["Aria", "AriaTools"],
            path: "Sources/AriaToolsJS"
        ),

        // AriaVoice has no Aria-core dependency — it's a standalone
        // STT+TTS+controller library that consumers wire to their own
        // chat pipeline via `VoiceController.bindSender(_:)`. Sources
        // are guarded with `#if canImport(Speech) && canImport(AVFoundation)`,
        // so the target compiles empty on platforms (tvOS, Linux) that
        // lack one of those frameworks rather than failing the build.
        .target(
            name: "AriaVoice",
            dependencies: [],
            path: "Sources/AriaVoice"
        ),

        // AriaMLX target. mlx-swift's C++ backend needs Apple's
        // Accelerate / Metal headers — it can't build on Linux. The
        // MLX product dependencies are trait-gated AND
        // platform-gated; the source files use `#if ARIA_MLX` (a
        // compile-time define set by the same trait condition) so
        // the target compiles to nothing when the trait is off,
        // sidestepping the SPM behaviour where `canImport(...)` can
        // return true for a transitively-resolved module that the
        // target itself doesn't link.
        .target(
            name: "AriaMLX",
            dependencies: [
                "Aria",
                .product(
                    name: "MLXLLM",
                    package: "mlx-swift-lm",
                    condition: .when(platforms: [.iOS, .macOS, .visionOS], traits: ["MLX"])
                ),
                .product(
                    name: "MLXVLM",
                    package: "mlx-swift-lm",
                    condition: .when(platforms: [.iOS, .macOS, .visionOS], traits: ["MLX"])
                ),
                .product(
                    name: "MLXLMCommon",
                    package: "mlx-swift-lm",
                    condition: .when(platforms: [.iOS, .macOS, .visionOS], traits: ["MLX"])
                ),
                .product(
                    name: "MLXLMHuggingFace",
                    package: "swift-huggingface-mlx",
                    condition: .when(platforms: [.iOS, .macOS, .visionOS], traits: ["MLX"])
                ),
                .product(
                    name: "MLXLMTransformers",
                    package: "swift-transformers-mlx",
                    condition: .when(platforms: [.iOS, .macOS, .visionOS], traits: ["MLX"])
                ),
            ],
            path: "Sources/AriaMLX",
            swiftSettings: [
                .define("ARIA_MLX", .when(traits: ["MLX"])),
            ]
        ),

        // AriaVoiceKokoro target. iOS 18+ / macOS 15+ at runtime
        // (kokoro-ios fork's floor). Same trait-gating pattern as
        // AriaMLX — deps are conditional and sources use
        // `#if ARIA_VOICE_KOKORO`.
        .target(
            name: "AriaVoiceKokoro",
            dependencies: [
                "AriaVoice",
                .product(
                    name: "KokoroSwift",
                    package: "kokoro-ios",
                    condition: .when(traits: ["VoiceKokoro"])
                ),
                .product(
                    name: "MLX",
                    package: "mlx-swift",
                    condition: .when(traits: ["VoiceKokoro"])
                ),
                .product(
                    name: "MLXUtilsLibrary",
                    package: "MLXUtilsLibrary",
                    condition: .when(traits: ["VoiceKokoro"])
                ),
            ],
            path: "Sources/AriaVoiceKokoro",
            swiftSettings: [
                .define("ARIA_VOICE_KOKORO", .when(traits: ["VoiceKokoro"])),
            ]
        ),

        // Workflow runtime. Depends on the existing Aria core (for
        // `StateGraph`, `Agent`, `JSONValue`) plus AriaTools +
        // AriaToolsJS for the JS bridge surface. Native-capability
        // code paths (HealthKit / EventKit / CoreLocation /
        // PDFKit / LocalAuthentication / Security framework) are
        // `#if canImport(...)`-guarded so the target compiles on
        // Linux as an empty shell.
        .target(
            name: "WorkflowKit",
            dependencies: [
                "Aria",
                "AriaTools",
                "AriaToolsJS",
                // GRDB powers the on-disk workflow store. Apple-only,
                // so the `Storage/` subfolder is wrapped in
                // `#if canImport(GRDB)` and the target compiles empty
                // on Linux. Same dep AriaApple already uses; SPM
                // resolves a single GRDB instance for the package.
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/WorkflowKit"
        ),

        // MARK: - Test targets

        .testTarget(
            name: "AriaTests",
            dependencies: ["Aria", "AriaTesting"],
            path: "Tests/AriaTests"
        ),

        .testTarget(
            name: "AriaAppleTests",
            dependencies: ["Aria", "AriaApple", "AriaTesting"],
            path: "Tests/AriaAppleTests"
        ),

        .testTarget(
            name: "AriaToolsTests",
            dependencies: ["Aria", "AriaTools", "AriaTesting"],
            path: "Tests/AriaToolsTests"
        ),

        .testTarget(
            name: "AriaToolsJSTests",
            dependencies: ["Aria", "AriaTools", "AriaToolsJS", "AriaTesting"],
            path: "Tests/AriaToolsJSTests"
        ),

        // AriaMLXTests source references `ARIA_MLX`-gated symbols
        // (ChatTemplateInspector, parsers, etc.). Mirroring the
        // define here lets the tests compile to empty when the
        // `MLX` trait is off and exercise the gated code when it's
        // on — same `#if ARIA_MLX` guard in the test sources.
        .testTarget(
            name: "AriaMLXTests",
            dependencies: ["Aria", "AriaMLX", "AriaTesting"],
            path: "Tests/AriaMLXTests",
            swiftSettings: [
                .define("ARIA_MLX", .when(traits: ["MLX"])),
            ]
        ),

        .testTarget(
            name: "WorkflowKitTests",
            dependencies: ["WorkflowKit", "Aria", "AriaTesting"],
            path: "Tests/WorkflowKitTests"
        ),

        // MARK: - Apps

        .executableTarget(
            name: "AriaCLI",
            dependencies: ["Aria", "AriaTesting"],
            path: "Apps/AriaCLI"
        ),
    ]
)
