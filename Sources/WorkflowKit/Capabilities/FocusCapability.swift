import Aria
import Foundation

// MARK: - FocusCapability

/// Read-only access to iOS Focus state. One method:
///
///   * `current()` — returns
///     `{ name: "<focus-id>" | null, isActive: Bool }`. The
///     name is `"active"` on iOS today; the wire format
///     leaves room for richer values if Apple ever exposes
///     the specific focus identifier.
///
/// First-use auth is implicit in `INFocusStatusCenter` — iOS
/// shows the prompt the first time we read.
public actor FocusCapability: Capability {
    // MARK: Lifecycle

    public init(backend: any FocusBackend) {
        self.backend = backend
    }

    // MARK: Public

    // MARK: Capability

    public nonisolated var id: CapabilityID {
        .focus
    }

    public nonisolated var supportedMethods: Set<String> {
        Self.allMethods
    }

    public func call(
        method: String,
        arguments _: [String: JSONValue],
        context _: CapabilityCallContext
    ) async throws -> JSONValue {
        switch method {
        case "current":
            return try await self.handleCurrent()
        default:
            throw CapabilityError.unknownMethod(capability: .focus, method: method)
        }
    }

    // MARK: Internal

    static let allMethods: Set<String> = ["current"]

    // MARK: Private

    private let backend: any FocusBackend

    private func handleCurrent() async throws -> JSONValue {
        do {
            let name = try await self.backend.currentFocus()
            if let name {
                return .object([
                    "name": .string(name),
                    "isActive": .bool(true),
                ])
            }
            return .object([
                "name": .null,
                "isActive": .bool(false),
            ])
        } catch {
            throw CapabilityError.unavailable(reason: String(describing: error))
        }
    }
}
