import Aria
import Foundation
import Testing
@testable import WorkflowKit

// MARK: - SecretsCapabilityTests

/// Coverage for the partitioned-keychain semantics + biometric
/// gating. Uses `InMemoryKeychainBackend` so nothing escapes the
/// test process and there's no per-test residue.
struct SecretsCapabilityTests {
    // MARK: Internal

    // MARK: - Basic CRUD

    @Test
    func setThenGetReturnsValue() async throws {
        let capability = Self.makeCapability(authenticator: AlwaysApproveAuthenticator())

        try await Self.set(capability, plugin: "p.weather", name: "API_KEY", value: "abc123")
        let value = try await Self.get(capability, plugin: "p.weather", name: "API_KEY")

        #expect(value == .string("abc123"))
    }

    @Test
    func getOfMissingKeyReturnsNull() async throws {
        let capability = Self.makeCapability(authenticator: AlwaysApproveAuthenticator())

        let value = try await Self.get(capability, plugin: "p.weather", name: "MISSING")

        #expect(value == .null)
    }

    @Test
    func deleteRemovesKeyAndBiometricFlag() async throws {
        let capability = Self.makeCapability(authenticator: AlwaysApproveAuthenticator())

        try await Self.set(capability, plugin: "p.weather", name: "API_KEY", value: "x")
        try await Self.setBiometric(capability, plugin: "p.weather", name: "API_KEY", required: true)

        // Flag is on
        let preFlag = try await Self.isBiometric(capability, plugin: "p.weather", name: "API_KEY")
        #expect(preFlag == .bool(true))

        try await Self.delete(capability, plugin: "p.weather", name: "API_KEY")

        // Both value and flag are gone
        let value = try await Self.get(capability, plugin: "p.weather", name: "API_KEY")
        let postFlag = try await Self.isBiometric(capability, plugin: "p.weather", name: "API_KEY")
        #expect(value == .null)
        #expect(postFlag == .bool(false))
    }

    @Test
    func setOverwritesExisting() async throws {
        let capability = Self.makeCapability(authenticator: AlwaysApproveAuthenticator())

        try await Self.set(capability, plugin: "p.x", name: "K", value: "v1")
        try await Self.set(capability, plugin: "p.x", name: "K", value: "v2")
        let value = try await Self.get(capability, plugin: "p.x", name: "K")

        #expect(value == .string("v2"))
    }

    // MARK: - Per-plugin partitioning

    @Test
    func pluginsCannotSeeEachOthersKeys() async throws {
        let capability = Self.makeCapability(authenticator: AlwaysApproveAuthenticator())

        try await Self.set(capability, plugin: "p.alice", name: "K", value: "alice-secret")
        try await Self.set(capability, plugin: "p.bob", name: "K", value: "bob-secret")

        let aliceValue = try await Self.get(capability, plugin: "p.alice", name: "K")
        let bobValue = try await Self.get(capability, plugin: "p.bob", name: "K")

        #expect(aliceValue == .string("alice-secret"))
        #expect(bobValue == .string("bob-secret"))
    }

    @Test
    func listOnlyReturnsCallerKeys() async throws {
        let capability = Self.makeCapability(authenticator: AlwaysApproveAuthenticator())

        try await Self.set(capability, plugin: "p.alice", name: "A1", value: "x")
        try await Self.set(capability, plugin: "p.alice", name: "A2", value: "x")
        try await Self.set(capability, plugin: "p.bob", name: "B1", value: "x")

        let aliceList = try await Self.list(capability, plugin: "p.alice")
        let bobList = try await Self.list(capability, plugin: "p.bob")

        #expect(aliceList == .array([.string("A1"), .string("A2")]))
        #expect(bobList == .array([.string("B1")]))
    }

    // MARK: - Biometric gating

    @Test
    func biometricFlagPersistsAcrossSets() async throws {
        let capability = Self.makeCapability(authenticator: AlwaysApproveAuthenticator())

        try await Self.set(capability, plugin: "p.x", name: "K", value: "v")
        try await Self.setBiometric(capability, plugin: "p.x", name: "K", required: true)

        // Rotate the value — biometric flag should survive.
        try await Self.set(capability, plugin: "p.x", name: "K", value: "v2")

        let flag = try await Self.isBiometric(capability, plugin: "p.x", name: "K")
        #expect(flag == .bool(true))
    }

    @Test
    func biometricFlagCanBeTurnedOff() async throws {
        let capability = Self.makeCapability(authenticator: AlwaysApproveAuthenticator())

        try await Self.set(capability, plugin: "p.x", name: "K", value: "v")
        try await Self.setBiometric(capability, plugin: "p.x", name: "K", required: true)
        try await Self.setBiometric(capability, plugin: "p.x", name: "K", required: false)

        let flag = try await Self.isBiometric(capability, plugin: "p.x", name: "K")
        #expect(flag == .bool(false))
    }

    @Test
    func biometricGatedReadSucceedsWithApprovedAuthenticator() async throws {
        let capability = Self.makeCapability(authenticator: AlwaysApproveAuthenticator())

        try await Self.set(capability, plugin: "p.x", name: "K", value: "v")
        try await Self.setBiometric(capability, plugin: "p.x", name: "K", required: true)

        let value = try await Self.get(capability, plugin: "p.x", name: "K", attended: true)
        #expect(value == .string("v"))
    }

    @Test
    func biometricGatedReadReturnsNullWhenDenied() async throws {
        let capability = Self.makeCapability(authenticator: AlwaysDenyAuthenticator())

        try await Self.set(capability, plugin: "p.x", name: "K", value: "v")
        try await Self.setBiometric(capability, plugin: "p.x", name: "K", required: true)

        let value = try await Self.get(capability, plugin: "p.x", name: "K", attended: true)
        #expect(value == .null)
    }

    @Test
    func biometricGatedReadReturnsNullForUnattendedRun() async throws {
        let capability = Self.makeCapability(authenticator: AlwaysApproveAuthenticator())

        try await Self.set(capability, plugin: "p.x", name: "K", value: "v")
        try await Self.setBiometric(capability, plugin: "p.x", name: "K", required: true)

        // Unattended (Siri / widget / scheduled): can't prompt,
        // must degrade. Authenticator that would approve is
        // irrelevant — we don't even ask it.
        let value = try await Self.get(capability, plugin: "p.x", name: "K", attended: false)
        #expect(value == .null)
    }

    @Test
    func nonBiometricKeyIsReturnedEvenWhenUnattended() async throws {
        let capability = Self.makeCapability(authenticator: AlwaysDenyAuthenticator())

        try await Self.set(capability, plugin: "p.x", name: "K", value: "v")
        // No biometric flag set.

        let value = try await Self.get(capability, plugin: "p.x", name: "K", attended: false)
        #expect(value == .string("v"))
    }

    // MARK: - Argument validation

    @Test
    func missingArgumentThrows() async {
        let capability = Self.makeCapability(authenticator: AlwaysApproveAuthenticator())

        await #expect(throws: CapabilityError.self) {
            _ = try await capability.call(
                method: "get",
                arguments: [:],
                context: Self.context(plugin: "p.x")
            )
        }
    }

    @Test
    func wrongArgumentTypeThrows() async {
        let capability = Self.makeCapability(authenticator: AlwaysApproveAuthenticator())

        await #expect(throws: CapabilityError.self) {
            _ = try await capability.call(
                method: "get",
                arguments: ["name": .integer(42)],
                context: Self.context(plugin: "p.x")
            )
        }
    }

    @Test
    func missingPluginIDInContextThrows() async {
        let capability = Self.makeCapability(authenticator: AlwaysApproveAuthenticator())

        let context = CapabilityCallContext(
            callerPluginID: nil,
            callerWorkflowID: nil,
            attended: true
        )
        await #expect(throws: CapabilityError.self) {
            _ = try await capability.call(
                method: "get",
                arguments: ["name": .string("X")],
                context: context
            )
        }
    }

    // MARK: Private

    // MARK: - Test helpers

    private static func makeCapability(
        authenticator: any BiometricAuthenticator
    ) -> SecretsCapability {
        SecretsCapability(
            backend: InMemoryKeychainBackend(),
            authenticator: authenticator
        )
    }

    private static func context(plugin: String, attended: Bool = true) -> CapabilityCallContext {
        CapabilityCallContext(
            callerPluginID: plugin,
            callerWorkflowID: nil,
            attended: attended
        )
    }

    private static func set(
        _ capability: SecretsCapability,
        plugin: String,
        name: String,
        value: String
    ) async throws {
        _ = try await capability.call(
            method: "set",
            arguments: ["name": .string(name), "value": .string(value)],
            context: self.context(plugin: plugin)
        )
    }

    private static func get(
        _ capability: SecretsCapability,
        plugin: String,
        name: String,
        attended: Bool = true
    ) async throws -> JSONValue {
        try await capability.call(
            method: "get",
            arguments: ["name": .string(name)],
            context: self.context(plugin: plugin, attended: attended)
        )
    }

    private static func delete(
        _ capability: SecretsCapability,
        plugin: String,
        name: String
    ) async throws {
        _ = try await capability.call(
            method: "delete",
            arguments: ["name": .string(name)],
            context: self.context(plugin: plugin)
        )
    }

    private static func list(
        _ capability: SecretsCapability,
        plugin: String
    ) async throws -> JSONValue {
        try await capability.call(
            method: "list",
            arguments: [:],
            context: self.context(plugin: plugin)
        )
    }

    private static func setBiometric(
        _ capability: SecretsCapability,
        plugin: String,
        name: String,
        required: Bool
    ) async throws {
        _ = try await capability.call(
            method: "setBiometricRequired",
            arguments: ["name": .string(name), "required": .bool(required)],
            context: self.context(plugin: plugin)
        )
    }

    private static func isBiometric(
        _ capability: SecretsCapability,
        plugin: String,
        name: String
    ) async throws -> JSONValue {
        try await capability.call(
            method: "isBiometricRequired",
            arguments: ["name": .string(name)],
            context: self.context(plugin: plugin)
        )
    }
}
