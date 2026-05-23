import Foundation

// MARK: - WorkflowKitInfo

/// Versioning sentinel for the `WorkflowKit` library. Used the same
/// way `AriaInfo.version` is used at the Aria-core layer — a tiny
/// always-present symbol so consumers (and the smoke test) have
/// something concrete to link and reference even before the full
/// surface lands.
///
/// The `WorkflowKit` surface is rolled out in vertical slices.
/// This file serves as the public-API anchor; concrete types
/// live under `Model/`, `Engine/`, `Capabilities/`, `Storage/`,
/// and `Seed/`.
public enum WorkflowKitInfo {
    public static let version = "0.1.0"
}
