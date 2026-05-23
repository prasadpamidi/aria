import Aria
import Foundation
import Testing
@testable import WorkflowKit

// MARK: - CapabilityBrokerTests

/// Coverage for the routing + scope-enforcement logic.
/// `FakeCapability` is the test double — its `call` returns the
/// arguments back as a JSON object so assertions can verify both
/// "the right impl ran" and "the right arguments arrived."
struct CapabilityBrokerTests {
    // MARK: - Routing

    @Test
    func callForwardsToRegisteredCapability() async throws {
        let broker = CapabilityBroker()
        let fake = FakeCapability(id: .health, methods: ["recentSteps"])
        await broker.register(fake)
        await broker.grant(CapabilityScope(pluginID: "p.test", capability: .health))

        let result = try await broker.call(
            capability: .health,
            method: "recentSteps",
            arguments: ["days": .integer(7)],
            callerPluginID: "p.test"
        )

        #expect(result == .object(["echoed": .integer(7)]))
    }

    @Test
    func unregisteredCapabilityFails() async {
        let broker = CapabilityBroker()
        await broker.grant(CapabilityScope(pluginID: "p.test", capability: .health))

        await #expect(throws: CapabilityError.self) {
            try await broker.call(
                capability: .health,
                method: "recentSteps",
                arguments: [:],
                callerPluginID: "p.test"
            )
        }
    }

    @Test
    func unknownMethodFails() async throws {
        let broker = CapabilityBroker()
        await broker.register(FakeCapability(id: .health, methods: ["recentSteps"]))
        await broker.grant(CapabilityScope(pluginID: "p.test", capability: .health))

        await #expect {
            try await broker.call(
                capability: .health,
                method: "futureMethod",
                arguments: [:],
                callerPluginID: "p.test"
            )
        } throws: { error in
            guard let capabilityError = error as? CapabilityError,
                  case let .unknownMethod(cap, method) = capabilityError else {
                return false
            }
            return cap == .health && method == "futureMethod"
        }
    }

    // MARK: - Scope enforcement

    @Test
    func ungrantedPluginFails() async throws {
        let broker = CapabilityBroker()
        await broker.register(FakeCapability(id: .secrets, methods: ["get"]))
        // No grant.

        await #expect {
            try await broker.call(
                capability: .secrets,
                method: "get",
                arguments: [:],
                callerPluginID: "p.untrusted"
            )
        } throws: { error in
            guard let capabilityError = error as? CapabilityError,
                  case let .notGranted(scope) = capabilityError else {
                return false
            }
            return scope.pluginID == "p.untrusted"
                && scope.capability == .secrets
                && scope.methods == ["get"]
        }
    }

    @Test
    func narrowScopeRejectsOtherMethods() async throws {
        let broker = CapabilityBroker()
        await broker.register(FakeCapability(id: .secrets, methods: ["get", "set"]))
        // Plugin only got "get" — "set" must still fail.
        await broker.grant(
            CapabilityScope(pluginID: "p.test", capability: .secrets, methods: ["get"])
        )

        // Allowed
        _ = try await broker.call(
            capability: .secrets,
            method: "get",
            arguments: [:],
            callerPluginID: "p.test"
        )

        // Denied
        await #expect(throws: CapabilityError.self) {
            try await broker.call(
                capability: .secrets,
                method: "set",
                arguments: [:],
                callerPluginID: "p.test"
            )
        }
    }

    @Test
    func builtinCallerSkipsScopeCheck() async throws {
        let broker = CapabilityBroker()
        await broker.register(FakeCapability(id: .calendar, methods: ["eventsToday"]))
        // No grant — first-party workflows are implicitly trusted.

        let result = try await broker.call(
            capability: .calendar,
            method: "eventsToday",
            arguments: [:],
            callerPluginID: "sdk.builtin.dailyBrief"
        )
        #expect(result == .object(["echoed": .object([:])]))
    }

    @Test
    func revokeRemovesScope() async {
        let broker = CapabilityBroker()
        let scope = CapabilityScope(pluginID: "p.x", capability: .health)
        await broker.grant(scope)
        var grants = await broker.allGrants
        #expect(grants.contains(scope))
        await broker.revoke(scope)
        grants = await broker.allGrants
        #expect(!grants.contains(scope))
    }

    @Test
    func revokeAllForPluginWipesPluginScopes() async {
        let broker = CapabilityBroker()
        await broker.grant(CapabilityScope(pluginID: "p.victim", capability: .health))
        await broker.grant(CapabilityScope(pluginID: "p.victim", capability: .calendar))
        await broker.grant(CapabilityScope(pluginID: "p.survivor", capability: .health))

        await broker.revokeAll(forPlugin: "p.victim")
        let remaining = await broker.allGrants

        #expect(remaining.count == 1)
        #expect(remaining.first?.pluginID == "p.survivor")
    }

    @Test
    func reregisteringReplacesCapability() async throws {
        let broker = CapabilityBroker()
        await broker.register(FakeCapability(id: .health, methods: ["a"]))
        await broker.register(FakeCapability(id: .health, methods: ["b"]))
        await broker.grant(CapabilityScope(pluginID: "p.x", capability: .health))

        // Second registration should answer; first method "a"
        // should no longer be supported.
        _ = try await broker.call(
            capability: .health,
            method: "b",
            arguments: [:],
            callerPluginID: "p.x"
        )

        await #expect(throws: CapabilityError.self) {
            try await broker.call(
                capability: .health,
                method: "a",
                arguments: [:],
                callerPluginID: "p.x"
            )
        }
    }
}

// MARK: - FakeCapability

/// Echo-style test double. Returns the arguments it received
/// (or, for `recentSteps`, just the `days` value) inside a JSON
/// object so tests can assert "this is the impl that ran" and
/// "with these arguments."
private struct FakeCapability: Capability {
    // MARK: Lifecycle

    init(id: CapabilityID, methods: Set<String>) {
        self.id = id
        self.supportedMethods = methods
    }

    // MARK: Internal

    let id: CapabilityID
    let supportedMethods: Set<String>

    func call(
        method: String,
        arguments: [String: JSONValue],
        context _: CapabilityCallContext
    ) async throws -> JSONValue {
        if method == "recentSteps", let days = arguments["days"] {
            return .object(["echoed": days])
        }
        return .object(["echoed": .object(arguments)])
    }
}
