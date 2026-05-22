import Aria
import Foundation

// MARK: - ShortcutsCapability

/// Invoke a user's iOS Shortcut from a workflow step. One method:
///
///   * `run({ name, input? })` — opens Shortcuts.app via
///     `shortcuts://run-shortcut?name=…&input=…`. Returns
///     `{ launched: Bool }` — `true` when the URL opened
///     successfully, `false` if the Shortcuts app couldn't
///     handle the URL (e.g. user has removed Shortcuts).
///
/// Behaviour by context:
///   - Interactive workflows fire the URL synchronously; the
///     Shortcut runs in Shortcuts.app and the user sees the
///     hand-off.
///   - Background workflows (Shortcuts / Siri / AppIntent)
///     can technically open URLs — iOS allows the calling
///     Shortcut to chain to another — though completion
///     observation isn't wired here.
public actor ShortcutsCapability: Capability {
    // MARK: Lifecycle

    public init(backend: any ShortcutsBackend) {
        self.backend = backend
    }

    // MARK: Public

    // MARK: Capability

    public nonisolated var id: CapabilityID {
        .shortcuts
    }

    public nonisolated var supportedMethods: Set<String> {
        Self.allMethods
    }

    public func call(
        method: String,
        arguments: [String: JSONValue],
        context _: CapabilityCallContext
    ) async throws -> JSONValue {
        switch method {
        case "run":
            return try await self.handleRun(arguments: arguments)
        default:
            throw CapabilityError.unknownMethod(capability: .shortcuts, method: method)
        }
    }

    // MARK: Internal

    static let allMethods: Set<String> = ["run"]

    // MARK: Private

    private let backend: any ShortcutsBackend

    private func handleRun(arguments: [String: JSONValue]) async throws -> JSONValue {
        guard case let .string(name) = arguments["name"], !name.isEmpty else {
            throw CapabilityError.invalidArguments(
                method: "run",
                expected: "argument 'name' of non-empty string",
                actual: String(describing: arguments["name"] ?? .null)
            )
        }
        let input: String? =
            if case let .string(value) = arguments["input"], !value.isEmpty {
                value
            } else {
                nil
            }
        let launched = try await self.backend.run(name: name, input: input)
        return .object(["launched": .bool(launched)])
    }
}
