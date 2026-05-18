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
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
        // OpenTelemetry-compatible tracing + metrics. The libraries are
        // protocol-only and ship with no-op defaults; consumers wire up
        // an exporter (swift-otel, etc.) at process start to send data
        // anywhere. Aria emits OTel GenAI semantic-convention attributes.
        .package(url: "https://github.com/apple/swift-distributed-tracing.git", from: "1.1.2"),
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

        // MARK: - Apps

        .executableTarget(
            name: "AriaCLI",
            dependencies: ["Aria", "AriaTesting"],
            path: "Apps/AriaCLI"
        ),
    ]
)
