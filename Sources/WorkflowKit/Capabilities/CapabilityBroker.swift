import Aria
import Foundation

// MARK: - CapabilityBroker

/// Central dispatcher for every capability call. Two
/// responsibilities:
///
///   1. **Routing** — given a `CapabilityID` + method name, find
///      the registered `Capability` impl and forward the call.
///   2. **Scope enforcement** — verify the caller has been
///      granted the capability + method before forwarding. Throws
///      `CapabilityError.notGranted` when they haven't, with a
///      payload telling the consent layer what to ask for.
///
/// Built as an actor so registration + grant state are protected
/// across concurrent callers. Capabilities themselves are
/// `Sendable` and stateless from the broker's perspective.
public actor CapabilityBroker {
    // MARK: Lifecycle

    public init() { }

    // MARK: Public

    /// All current grants. Surfaced for the Settings UI ("Stored
    /// keys" / "Permissions" rows) and for diagnostics. Read-only
    /// snapshot; mutations go through `grant` / `revoke`.
    public var allGrants: Set<CapabilityScope> {
        self.grants
    }

    /// Register a capability impl. Replaces any prior registration
    /// for the same `id` — registration order doesn't matter and
    /// idempotent re-registration is allowed (useful in test
    /// teardown / hot-reload).
    public func register(_ capability: any Capability) {
        self.capabilities[capability.id] = capability
    }

    /// Grant a scope. Persists into the broker's in-memory grant
    /// table; the host app is responsible for serialising this to
    /// disk via its own storage layer when it wants grants to
    /// survive launches.
    public func grant(_ scope: CapabilityScope) {
        self.grants.insert(scope)
    }

    /// Revoke a scope. Match is exact (pluginID + capability +
    /// methods). Use `revokeAll(forPlugin:)` for the "uninstall"
    /// path that wipes everything for a caller.
    public func revoke(_ scope: CapabilityScope) {
        self.grants.remove(scope)
    }

    /// Wipe every scope for a given caller. Called when the user
    /// uninstalls a plugin so no orphan grants survive.
    public func revokeAll(forPlugin pluginID: String) {
        self.grants = self.grants.filter { $0.pluginID != pluginID }
    }

    /// Execute one capability call. Verifies the caller's scope
    /// before forwarding to the registered capability impl.
    @discardableResult
    public func call(
        capability id: CapabilityID,
        method: String,
        arguments: [String: JSONValue],
        callerPluginID: String,
        attended: Bool = true,
        callerWorkflowID: UUID? = nil
    ) async throws -> JSONValue {
        // 1. Find the impl
        guard let capability = self.capabilities[id] else {
            throw CapabilityError.unavailable(
                reason: "No capability registered for \(id.rawValue)"
            )
        }

        // 2. Method existence
        guard capability.supportedMethods.contains(method) else {
            throw CapabilityError.unknownMethod(capability: id, method: method)
        }

        // 3. Scope check. First-party callers (workflows shipped
        // with the app) get an implicit grant; user-installed
        // plugins must have been explicitly granted at install.
        if !Self.isFirstPartyCaller(callerPluginID) {
            let scope = self.matchingScope(
                pluginID: callerPluginID,
                capability: id,
                method: method
            )
            guard let scope else {
                throw CapabilityError.notGranted(
                    CapabilityScope(
                        pluginID: callerPluginID,
                        capability: id,
                        methods: [method]
                    )
                )
            }
            _ = scope
        }

        // 4. Dispatch
        let context = CapabilityCallContext(
            callerPluginID: callerPluginID,
            callerWorkflowID: callerWorkflowID,
            attended: attended
        )
        return try await capability.call(
            method: method,
            arguments: arguments,
            context: context
        )
    }

    // MARK: Internal

    /// Caller ids prefixed with `avyra.builtin.` skip the scope
    /// check — they're shipped-with-the-app workflows. JS plugins
    /// always use a reverse-DNS bundle id that doesn't collide
    /// with this prefix, so the check is one string compare and
    /// safe against impersonation.
    static func isFirstPartyCaller(_ pluginID: String) -> Bool {
        pluginID.hasPrefix("avyra.builtin.")
    }

    // MARK: Private

    private var capabilities: [CapabilityID: any Capability] = [:]
    private var grants: Set<CapabilityScope> = []

    /// Find the most-specific scope that covers a method call.
    /// `methods == nil` (broad) wins over a narrow allowlist only
    /// if the narrow allowlist doesn't include the requested
    /// method.
    private func matchingScope(
        pluginID: String,
        capability: CapabilityID,
        method: String
    ) -> CapabilityScope? {
        self.grants.first { scope in
            scope.pluginID == pluginID
                && scope.capability == capability
                && scope.includes(method: method)
        }
    }
}
