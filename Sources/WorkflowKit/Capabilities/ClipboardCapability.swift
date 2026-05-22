import Aria
import Foundation

// MARK: - ClipboardCapability

/// `UIPasteboard`-backed read + write. Two methods:
///
///   * `read()` — returns `{ "text": "..." }` if the clipboard
///     holds string content, or `{ "text": null }` when empty /
///     non-text. The return shape is intentionally an object
///     (not bare string) so workflow templates can branch on
///     `b.clip.text == null` without special casing.
///   * `write({ text })` — sets the clipboard string. Returns
///     `{ "ok": true }` so downstream branches can confirm.
///
/// No first-use authorization — iOS 14+ shows a system toast
/// on every read but doesn't gate the call. The capability
/// therefore skips the `ensureAuthorized` dance every other
/// capability does.
public actor ClipboardCapability: Capability {
    // MARK: Lifecycle

    public init(backend: any ClipboardBackend) {
        self.backend = backend
    }

    // MARK: Public

    // MARK: Capability

    public nonisolated var id: CapabilityID {
        .clipboard
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
        case "read":
            return try await self.handleRead()
        case "write":
            return try await self.handleWrite(arguments: arguments)
        default:
            throw CapabilityError.unknownMethod(capability: .clipboard, method: method)
        }
    }

    // MARK: Internal

    static let allMethods: Set<String> = ["read", "write"]

    // MARK: Private

    private let backend: any ClipboardBackend

    private func handleRead() async throws -> JSONValue {
        let value = await self.backend.read()
        if let value {
            return .object(["text": .string(value)])
        }
        return .object(["text": .null])
    }

    private func handleWrite(arguments: [String: JSONValue]) async throws -> JSONValue {
        guard case let .string(text) = arguments["text"] else {
            throw CapabilityError.invalidArguments(
                method: "write",
                expected: "argument 'text' of type string",
                actual: String(describing: arguments["text"] ?? .null)
            )
        }
        await self.backend.write(text)
        return .object(["ok": .bool(true)])
    }
}
