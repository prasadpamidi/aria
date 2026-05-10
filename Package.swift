// swift-tools-version: 6.1
//
// Aria — Composable on-device agent runtime for Apple platforms.
// See docs/ for architecture and design.

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

        // Apple-platform implementations: FoundationModels, MLX, Core ML,
        // NLEmbedding, SwiftData, sqlite-vec, OSLog backends.
        .library(name: "AriaApple", targets: ["AriaApple"]),

        // Cross-platform tool implementations.
        .library(name: "AriaTools", targets: ["AriaTools"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
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

        // MARK: - Examples

        .executableTarget(
            name: "AriaCLI",
            dependencies: ["Aria", "AriaTesting"],
            path: "Examples/AriaCLI"
        ),
    ]
)
