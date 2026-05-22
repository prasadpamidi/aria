import Foundation

// MARK: - ShortcutsBackend

/// Injection seam for invoking iOS Shortcuts via the
/// `shortcuts://` URL scheme. Production
/// `ShortcutsCapability` uses `UIKitShortcutsBackend`; tests
/// use `InMemoryShortcutsBackend` so the runner can verify
/// dispatch without touching the Shortcuts app.
public protocol ShortcutsBackend: Sendable {
    /// Open the Shortcuts app and run the named shortcut.
    /// Optional `input` is passed via the `input` query
    /// parameter (Shortcuts surfaces it as the shortcut's
    /// "Shortcut Input"). Returns `true` when the URL launch
    /// succeeded — Shortcuts itself runs asynchronously and
    /// reports completion via its own callback URL, which we
    /// don't currently subscribe to.
    func run(name: String, input: String?) async throws -> Bool
}

// MARK: - InMemoryShortcutsBackend

/// Test-only backend. Records every dispatch + lets the test
/// pin the boolean result.
public actor InMemoryShortcutsBackend: ShortcutsBackend {
    // MARK: Lifecycle

    public init(launchSucceeded: Bool = true) {
        self.launchSucceeded = launchSucceeded
    }

    // MARK: Public

    public func run(name: String, input: String?) async throws -> Bool {
        self.dispatched.append((name: name, input: input))
        return self.launchSucceeded
    }

    /// Inspection hook for tests.
    public func dispatchedShortcuts() -> [(name: String, input: String?)] {
        self.dispatched
    }

    // MARK: Private

    private let launchSucceeded: Bool
    private var dispatched: [(name: String, input: String?)] = []
}
