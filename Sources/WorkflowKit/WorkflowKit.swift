import Foundation

// MARK: - WorkflowKitInfo

/// Versioning sentinel for the `WorkflowKit` library. Used the same
/// way `AriaInfo.version` is used at the Aria-core layer — a tiny
/// always-present symbol so consumers (and the smoke test) have
/// something concrete to link and reference even before the full
/// surface lands.
///
/// The whole `WorkflowKit` surface is rolled out in vertical
/// slices (see `docs/plans/2026-05-20-avyra-workflows-p0-plan.md`).
/// Each slice adds another concrete type — for now this file is
/// intentionally the only non-empty source so the target builds.
public enum WorkflowKitInfo {
    public static let version = "0.1.0"
}
