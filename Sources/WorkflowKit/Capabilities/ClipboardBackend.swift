import Foundation

// MARK: - ClipboardBackend

/// Injection seam for `UIPasteboard`. Production
/// `ClipboardCapability` uses `UIKitClipboardBackend`; tests use
/// `InMemoryClipboardBackend` so the runner doesn't need the
/// real pasteboard (which is process-global and noisy to share
/// across tests).
public protocol ClipboardBackend: Sendable {
    /// Returns the clipboard's current string content, or `nil`
    /// when the pasteboard is empty / holds non-text data. iOS
    /// 14+ shows a system "Pasted from <App>" banner on every
    /// read — by design, no permission gate.
    func read() async -> String?

    /// Replace the clipboard's string content. Atomic with
    /// respect to subsequent reads.
    func write(_ text: String) async
}

// MARK: - InMemoryClipboardBackend

/// Test-only deterministic backend. Holds the current content
/// in an actor-protected slot so concurrent writes don't tear.
public actor InMemoryClipboardBackend: ClipboardBackend {
    // MARK: Lifecycle

    public init(initial: String? = nil) {
        self.content = initial
    }

    // MARK: Public

    // MARK: ClipboardBackend

    public func read() async -> String? {
        self.content
    }

    public func write(_ text: String) async {
        self.content = text
    }

    // MARK: Private

    private var content: String?
}
