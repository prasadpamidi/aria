import Foundation

// MARK: - ShareBackend

/// Injection seam for `UIActivityViewController`. Production
/// `ShareCapability` uses `UIKitShareBackend`; tests use
/// `InMemoryShareBackend` so the runner never has to find a
/// presenter VC.
public protocol ShareBackend: Sendable {
    /// Present the share sheet with `text` as the activity
    /// item. Returns `true` when the user completes an
    /// activity (sent, copied, etc.), `false` when they
    /// dismiss without acting. Throws when the presenter
    /// can't be found — the workflow's interactive context
    /// must have a window to present from.
    func share(text: String) async throws -> Bool
}

// MARK: - InMemoryShareBackend

/// Test-only backend. Records every share attempt; reads the
/// configured `completionPolicy` to decide whether to report
/// success / cancel. Default reports `true` — match the
/// happy-path expectation.
public actor InMemoryShareBackend: ShareBackend {
    // MARK: Lifecycle

    public init(completionPolicy: CompletionPolicy = .completed) {
        self.completionPolicy = completionPolicy
    }

    // MARK: Public

    public enum CompletionPolicy: Sendable {
        case completed
        case cancelled
        case throwing(any Error & Sendable)
    }

    public func share(text: String) async throws -> Bool {
        self.shared.append(text)
        switch self.completionPolicy {
        case .completed:
            return true
        case .cancelled:
            return false
        case let .throwing(error):
            throw error
        }
    }

    /// Inspection hook for tests.
    public func sharedTexts() -> [String] {
        self.shared
    }

    // MARK: Private

    private let completionPolicy: CompletionPolicy
    private var shared: [String] = []
}
