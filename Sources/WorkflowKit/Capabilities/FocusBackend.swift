import Foundation

// MARK: - FocusBackend

/// Injection seam for reading iOS Focus state. Apple gates
/// programmatic *write* to Focus (security/privacy choice) so
/// this backend only reads — workflows that want to suggest a
/// Focus switch open the system picker via the share /
/// Shortcuts path instead.
public protocol FocusBackend: Sendable {
    /// Returns the active focus's identifier (`work`,
    /// `personal`, `sleep`, `do_not_disturb`, …) when one is
    /// active, otherwise `nil`. iOS expresses Focus state as
    /// an `INFocusStatus` whose `isFocused` is `false` when no
    /// focus is active.
    func currentFocus() async throws -> String?
}

// MARK: - InMemoryFocusBackend

/// Test-only backend. Fixed state set at construction time.
public struct InMemoryFocusBackend: FocusBackend {
    // MARK: Lifecycle

    public init(currentFocus: String? = nil, error: (any Error)? = nil) {
        self.fixture = currentFocus
        self.error = error
    }

    // MARK: Public

    public func currentFocus() async throws -> String? {
        if let error {
            throw error
        }
        return self.fixture
    }

    // MARK: Private

    private let fixture: String?
    private let error: (any Error)?
}
