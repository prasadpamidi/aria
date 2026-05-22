import Aria
import Foundation
import Testing
@testable import WorkflowKit

// MARK: - FocusCapabilityTests

struct FocusCapabilityTests {
    // MARK: Internal

    @Test
    func currentReturnsActiveWhenFocused() async throws {
        let backend = InMemoryFocusBackend(currentFocus: "work")
        let capability = FocusCapability(backend: backend)
        let result = try await capability.call(
            method: "current",
            arguments: [:],
            context: Self.context()
        )
        #expect(result == .object(["name": .string("work"), "isActive": .bool(true)]))
    }

    @Test
    func currentReturnsInactiveWhenNoFocus() async throws {
        let backend = InMemoryFocusBackend(currentFocus: nil)
        let capability = FocusCapability(backend: backend)
        let result = try await capability.call(
            method: "current",
            arguments: [:],
            context: Self.context()
        )
        #expect(result == .object(["name": .null, "isActive": .bool(false)]))
    }

    @Test
    func backendErrorSurfacesAsUnavailable() async throws {
        let backend = InMemoryFocusBackend(error: FocusError.permissionDenied)
        let capability = FocusCapability(backend: backend)
        await #expect(throws: CapabilityError.self) {
            try await capability.call(
                method: "current",
                arguments: [:],
                context: Self.context()
            )
        }
    }

    // MARK: Private

    private static func context() -> CapabilityCallContext {
        CapabilityCallContext(callerPluginID: "test", callerWorkflowID: nil, attended: true)
    }
}

// MARK: - ShortcutsCapabilityTests

struct ShortcutsCapabilityTests {
    // MARK: Internal

    @Test
    func runDispatchesShortcutByName() async throws {
        let backend = InMemoryShortcutsBackend(launchSucceeded: true)
        let capability = ShortcutsCapability(backend: backend)
        let result = try await capability.call(
            method: "run",
            arguments: ["name": .string("Daily Brief")],
            context: Self.context()
        )
        #expect(result == .object(["launched": .bool(true)]))
        let history = await backend.dispatchedShortcuts()
        #expect(history.count == 1)
        #expect(history.first?.name == "Daily Brief")
        #expect(history.first?.input == nil)
    }

    @Test
    func runForwardsOptionalInput() async throws {
        let backend = InMemoryShortcutsBackend()
        let capability = ShortcutsCapability(backend: backend)
        _ = try await capability.call(
            method: "run",
            arguments: [
                "name": .string("Translate"),
                "input": .string("hello world"),
            ],
            context: Self.context()
        )
        let history = await backend.dispatchedShortcuts()
        #expect(history.first?.input == "hello world")
    }

    @Test
    func runReportsLaunchFailure() async throws {
        let backend = InMemoryShortcutsBackend(launchSucceeded: false)
        let capability = ShortcutsCapability(backend: backend)
        let result = try await capability.call(
            method: "run",
            arguments: ["name": .string("MissingShortcut")],
            context: Self.context()
        )
        #expect(result == .object(["launched": .bool(false)]))
    }

    @Test
    func runRejectsEmptyName() async throws {
        let backend = InMemoryShortcutsBackend()
        let capability = ShortcutsCapability(backend: backend)
        await #expect(throws: CapabilityError.self) {
            try await capability.call(
                method: "run",
                arguments: ["name": .string("")],
                context: Self.context()
            )
        }
    }

    // MARK: Private

    private static func context() -> CapabilityCallContext {
        CapabilityCallContext(callerPluginID: "test", callerWorkflowID: nil, attended: true)
    }
}
