import Aria
import Foundation
import Testing
@testable import WorkflowKit

// MARK: - ShareCapabilityTests

/// Coverage for the share-sheet capability via
/// `InMemoryShareBackend`. The real `UIActivityViewController`
/// path needs a window to present from, which the test runner
/// doesn't have.
struct ShareCapabilityTests {
    // MARK: Internal

    @Test
    func shareTextReportsCompletionAndRecordsContent() async throws {
        let backend = InMemoryShareBackend(completionPolicy: .completed)
        let capability = ShareCapability(backend: backend)
        let result = try await capability.call(
            method: "shareText",
            arguments: ["text": .string("hello world")],
            context: Self.context(attended: true)
        )
        #expect(result == .object(["completed": .bool(true)]))
        let recorded = await backend.sharedTexts()
        #expect(recorded == ["hello world"])
    }

    @Test
    func shareTextReportsCancellationWhenUserDismisses() async throws {
        let backend = InMemoryShareBackend(completionPolicy: .cancelled)
        let capability = ShareCapability(backend: backend)
        let result = try await capability.call(
            method: "shareText",
            arguments: ["text": .string("oops")],
            context: Self.context(attended: true)
        )
        #expect(result == .object(["completed": .bool(false)]))
    }

    @Test
    func backgroundContextFailsClosed() async throws {
        // Background workflows (Shortcuts / Siri / AppIntent)
        // can't present a share sheet — the capability must
        // refuse rather than silently no-op.
        let backend = InMemoryShareBackend()
        let capability = ShareCapability(backend: backend)
        await #expect(throws: CapabilityError.self) {
            try await capability.call(
                method: "shareText",
                arguments: ["text": .string("noop")],
                context: Self.context(attended: false)
            )
        }
        // Backend was never asked.
        let recorded = await backend.sharedTexts()
        #expect(recorded.isEmpty)
    }

    @Test
    func shareTextRejectsNonStringText() async throws {
        let backend = InMemoryShareBackend()
        let capability = ShareCapability(backend: backend)
        await #expect(throws: CapabilityError.self) {
            try await capability.call(
                method: "shareText",
                arguments: ["text": .integer(42)],
                context: Self.context(attended: true)
            )
        }
    }

    @Test
    func unknownMethodThrows() async throws {
        let backend = InMemoryShareBackend()
        let capability = ShareCapability(backend: backend)
        await #expect(throws: CapabilityError.self) {
            try await capability.call(
                method: "unknown",
                arguments: [:],
                context: Self.context(attended: true)
            )
        }
    }

    // MARK: Private

    private static func context(attended: Bool) -> CapabilityCallContext {
        CapabilityCallContext(
            callerPluginID: "avyra.builtin.test",
            callerWorkflowID: nil,
            attended: attended
        )
    }
}
