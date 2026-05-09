import Aria

/// AriaTesting — Mocks, fixtures, and test helpers for Aria.
///
/// This module ships scripted providers, deterministic embedders, recording
/// observers, and other utilities that make agent tests fast, deterministic,
/// and Linux-friendly.
///
/// Intended targets that depend on `AriaTesting`:
/// - `AriaTests` (core unit tests)
/// - `AriaAppleTests` (Apple-specific tests that still use mocks for some layers)
/// - Consumer test targets
public enum AriaTesting {
    /// The current version. Matches `AriaInfo.version` in lockstep.
    public static let version = AriaInfo.version
}
