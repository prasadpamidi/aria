import Testing
@testable import WorkflowKit

// MARK: - WorkflowKitVersionTests

/// Smoke test: the target builds, links, and the version sentinel
/// resolves. The full WorkflowKit surface arrives in subsequent
/// slices (see `docs/plans/2026-05-20-avyra-workflows-p0-plan.md`).
struct WorkflowKitVersionTests {
    @Test
    func versionIsAvailable() {
        #expect(!WorkflowKitInfo.version.isEmpty)
    }
}
