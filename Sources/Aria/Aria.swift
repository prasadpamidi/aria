import Foundation
import Logging

// MARK: - Aria

/// Aria — Composable on-device agent runtime for Apple platforms.
///
/// This is the platform-agnostic core. The protocols and types in this module
/// describe agent orchestration, the LLM provider boundary, memory, and the
/// optional graph layer — all without any Apple-platform dependencies.
///
/// For Apple-specific implementations (FoundationModels, MLX, Core ML,
/// NLEmbedding, SwiftData, sqlite-vec, OSLog) see the `AriaApple` module.
///
/// Documentation lives in the `docs/` folder of the repository, organized by
/// architectural layer. Start with `docs/overview.md`.
public enum Aria {
    /// The current version of Aria.
    ///
    /// Aria follows semantic versioning once it reaches `1.0.0`. Until then,
    /// breaking changes may occur on minor version bumps.
    public static let version = "0.0.1-alpha.1"
}

/// Internal logger used by core types. Backends are installed by the platform
/// module (e.g., `AriaApple` installs an `OSLog` backend) or by the consumer.
let ariaLogger = Logger(label: "com.aria.core")
