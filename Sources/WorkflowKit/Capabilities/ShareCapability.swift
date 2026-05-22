import Aria
import Foundation

// MARK: - ShareCapability

/// `UIActivityViewController`-backed share sheet. One method:
///
///   * `shareText({ text })` — present the system share sheet
///     with the given string. Returns
///     `{ "completed": true|false }` — `true` when the user
///     chose an activity, `false` when they dismissed without
///     acting. Throws when no window is available to present
///     from (e.g. background contexts).
///
/// Requires an interactive context. Workflows triggered from
/// Shortcuts / Siri / background AppIntents fail closed with
/// `.unavailable` — the share sheet isn't presentable when the
/// app isn't in the foreground.
public actor ShareCapability: Capability {
    // MARK: Lifecycle

    public init(backend: any ShareBackend) {
        self.backend = backend
    }

    // MARK: Public

    // MARK: Capability

    public nonisolated var id: CapabilityID {
        .share
    }

    public nonisolated var supportedMethods: Set<String> {
        Self.allMethods
    }

    public func call(
        method: String,
        arguments: [String: JSONValue],
        context: CapabilityCallContext
    ) async throws -> JSONValue {
        guard context.attended else {
            throw CapabilityError
                .unavailable(
                    reason: "Share sheet requires an interactive context. Trigger the workflow from inside the app — Shortcuts / Siri / background AppIntent contexts can't present a sheet."
                )
        }
        switch method {
        case "shareText":
            return try await self.handleShareText(arguments: arguments)
        default:
            throw CapabilityError.unknownMethod(capability: .share, method: method)
        }
    }

    // MARK: Internal

    static let allMethods: Set<String> = ["shareText"]

    // MARK: Private

    private let backend: any ShareBackend

    private func handleShareText(arguments: [String: JSONValue]) async throws -> JSONValue {
        guard case let .string(text) = arguments["text"] else {
            throw CapabilityError.invalidArguments(
                method: "shareText",
                expected: "argument 'text' of type string",
                actual: String(describing: arguments["text"] ?? .null)
            )
        }
        do {
            let completed = try await self.backend.share(text: text)
            return .object(["completed": .bool(completed)])
        } catch let error as ShareError {
            throw CapabilityError.unavailable(reason: error.localizedDescription)
        }
    }
}
