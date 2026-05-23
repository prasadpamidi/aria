import Aria
import Foundation
import Testing
@testable import WorkflowKit

// MARK: - ClipboardCapabilityTests

/// Coverage for the `UIPasteboard`-backed capability using
/// `InMemoryClipboardBackend`. Real pasteboard interaction is
/// device-only and noisy in a test process — this suite owns
/// the capability's arg parsing + dispatch logic.
struct ClipboardCapabilityTests {
    // MARK: Internal

    @Test
    func readReturnsTextWhenClipboardHasContent() async throws {
        let backend = InMemoryClipboardBackend(initial: "hello world")
        let capability = ClipboardCapability(backend: backend)
        let result = try await capability.call(
            method: "read",
            arguments: [:],
            context: Self.context()
        )
        #expect(result == .object(["text": .string("hello world")]))
    }

    @Test
    func readReturnsNullWhenClipboardIsEmpty() async throws {
        let backend = InMemoryClipboardBackend(initial: nil)
        let capability = ClipboardCapability(backend: backend)
        let result = try await capability.call(
            method: "read",
            arguments: [:],
            context: Self.context()
        )
        #expect(result == .object(["text": .null]))
    }

    @Test
    func writeReplacesClipboardContent() async throws {
        let backend = InMemoryClipboardBackend(initial: "before")
        let capability = ClipboardCapability(backend: backend)
        let result = try await capability.call(
            method: "write",
            arguments: ["text": .string("after")],
            context: Self.context()
        )
        #expect(result == .object(["ok": .bool(true)]))

        // Round-trip — the next read sees the new content.
        let readBack = try await capability.call(
            method: "read",
            arguments: [:],
            context: Self.context()
        )
        #expect(readBack == .object(["text": .string("after")]))
    }

    @Test
    func writeRejectsNonStringText() async throws {
        let backend = InMemoryClipboardBackend()
        let capability = ClipboardCapability(backend: backend)
        await #expect(throws: CapabilityError.self) {
            try await capability.call(
                method: "write",
                arguments: ["text": .integer(42)],
                context: Self.context()
            )
        }
    }

    @Test
    func unknownMethodThrows() async throws {
        let backend = InMemoryClipboardBackend()
        let capability = ClipboardCapability(backend: backend)
        await #expect(throws: CapabilityError.self) {
            try await capability.call(
                method: "unknown",
                arguments: [:],
                context: Self.context()
            )
        }
    }

    // MARK: Private

    private static func context() -> CapabilityCallContext {
        CapabilityCallContext(
            callerPluginID: "sdk.builtin.test",
            callerWorkflowID: nil,
            attended: true
        )
    }
}
