import Foundation
import Logging

// MARK: - AriaInfo

/// Package metadata for Aria.
///
/// Named `AriaInfo` rather than `Aria` so the module name remains usable for
/// module-qualified type references inside the package
/// (e.g. `Aria.GenerationOptions` in modules that also import frameworks
/// with same-named types).
///
/// For the architecture and design, see the `docs/` folder of the
/// repository, starting with `docs/overview.md`.
public enum AriaInfo {
    /// The current version of Aria. Must be kept in lockstep with
    /// the most recent Git tag — consumer apps (e.g. Avyra's
    /// Settings → "Powered by Aria SDK" badge) read this at
    /// runtime, so a stale value lies to users about which SDK
    /// they're actually shipping against. Bump every release.
    ///
    /// Aria follows semantic versioning once it reaches `1.0.0`. Until then,
    /// breaking changes may occur on minor version bumps.
    public static let version = "0.6.1"
}

/// Internal logger used by core types. Backends are installed by the platform
/// module (e.g., `AriaApple` installs an `OSLog` backend) or by the consumer.
let ariaLogger = Logger(label: "com.aria.core")
