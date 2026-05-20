// swift-tools-version: 6.1
//
// Aria — Composable on-device agent runtime for Apple platforms.
// See docs/ for architecture and design.
//
// MLX-backed providers live in `./MLX/Package.swift` as a separate
// SwiftPM package. Consumers that only need FoundationModels (or any
// custom LLMProvider) should depend on this root package; consumers
// that need MLX models add a second SPM reference to `./MLX/`.

import PackageDescription

let package = Package(
    name: "Aria",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
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
        // `.avyra-tool` JSON bundles (manifest + embedded JS) and
        // vends them as `AnyTool`s the agent can call. Sandboxed
        // per-tool `JSContext`s; capabilities (HTTP, JSON, clipboard,
        // share, notify, storage) are gated by per-tool manifest
        // declarations enforced at bridge-construction time.
        .library(name: "AriaToolsJS", targets: ["AriaToolsJS"]),

        // Apple-platform voice: STT (Speech.framework), TTS protocol +
        // AVSpeechSynthesizer-backed default impl, and the voice-mode
        // state machine. Apps that want on-device higher-quality TTS
        // add `AriaVoiceKokoro` from the `./Voice/` sibling package.
        .library(name: "AriaVoice", targets: ["AriaVoice"]),

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
    dependencies: [
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
        // the `Avyra.*` bridge object that Swift authors use
        // natively. JavaScriptCore is Apple-only; sources are
        // guarded with `#if canImport(JavaScriptCore)` so the
        // target compiles empty on Linux.
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

        // Workflow runtime. Depends on the existing Aria core (for
        // `StateGraph`, `Agent`, `JSONValue`) plus AriaTools +
        // AriaToolsJS for the JS bridge surface. Native-capability
        // code paths (HealthKit / EventKit / CoreLocation /
        // PDFKit / LocalAuthentication / Security framework) are
        // `#if canImport(...)`-guarded so the target compiles on
        // Linux as an empty shell.
        .target(
            name: "WorkflowKit",
            dependencies: ["Aria", "AriaTools", "AriaToolsJS"],
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
