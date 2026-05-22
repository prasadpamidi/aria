import Foundation
#if canImport(Intents)
    import Intents

    // MARK: - INFocusBackend

    /// Production focus-state backend backed by
    /// `INFocusStatusCenter`. Reading requires the
    /// `NSFocusStatusUsageDescription` Info.plist key (handled
    /// at the app target) and a one-time permission prompt
    /// (`requestAuthorization`).
    ///
    /// The center reports `INFocusStatus` with an `isFocused`
    /// bool. Apple intentionally does NOT expose which specific
    /// Focus is active (Work / Personal / Sleep) — that's a
    /// privacy choice. We surface the bool as a synthetic name
    /// (`"active"` / nil) so the rest of the workflow surface
    /// can reason about Focus without us inventing details
    /// we don't have.
    public final class INFocusBackend: FocusBackend, @unchecked Sendable {
        // MARK: Lifecycle

        public init() { }

        // MARK: Public

        public func currentFocus() async throws -> String? {
            let status = INFocusStatusCenter.default.focusStatus
            if status.isFocused == true {
                return "active"
            }
            return nil
        }
    }
#endif

// MARK: - FocusError

public enum FocusError: LocalizedError, Sendable, Equatable {
    case permissionDenied

    // MARK: Public

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Avyra wasn't granted permission to read Focus state."
        }
    }
}
