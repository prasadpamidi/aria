import Foundation

// MARK: - CapabilityScope

/// One grant of one capability to one caller. The user-visible
/// view of "what does Echo Plugin have access to?" is a
/// collection of these scopes.
///
/// `methods` is the granular per-method allowlist. The common
/// case at install time is `methods == nil` — meaning "all
/// methods this capability ships." Future power-user surfaces
/// can narrow that to specific methods if we ship a manifest
/// option for it; the storage shape is ready.
public struct CapabilityScope: Codable, Sendable, Hashable {
    // MARK: Lifecycle

    public init(
        pluginID: String,
        capability: CapabilityID,
        methods: Set<String>? = nil
    ) {
        self.pluginID = pluginID
        self.capability = capability
        self.methods = methods
    }

    // MARK: Public

    /// Caller this scope is granted to. Plugin bundle id (`so.aria.example.weather`)
    /// for JS plugins; for first-party / built-in workflows this
    /// is the workflow's uuid string.
    public let pluginID: String
    /// Which capability is being scoped.
    public let capability: CapabilityID
    /// Method allowlist. `nil` means "every method this capability
    /// supports"; a non-empty set narrows to exactly those names.
    public let methods: Set<String>?

    /// Convenience: does this scope cover the requested method?
    public func includes(method: String) -> Bool {
        guard let methods = self.methods else {
            return true
        }
        return methods.contains(method)
    }
}
