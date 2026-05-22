import Aria
import Foundation

// MARK: - SecretsCapability

/// Keychain-backed secret vault, per-plugin scoped.
///
/// Layout in the underlying backend:
///
///   * **Value keys**     — `\(pluginID)::\(userKeyName)` →
///                          the secret string itself.
///   * **Biometric flags** — `__bio.\(pluginID)::\(userKeyName)` →
///                          `"1"` when the user has flipped the
///                          'Require Face ID' switch for that
///                          key. Stored separately so the value
///                          read doesn't need to mutate the flag
///                          state and so we can audit which keys
///                          are biometric-gated without
///                          unlocking them.
///
/// The capability layer takes `pluginID` from the call context;
/// plugins never see other plugins' keys.
///
/// **Unattended runs**: when `context.attended == false` and a
/// requested key is biometric-gated, `get` returns `nil` rather
/// than throwing. This lets a Siri-fired Daily Brief tolerate
/// missing keys (the workflow can fall back to a default) without
/// crashing in a code path that physically can't render a Face
/// ID prompt.
public struct SecretsCapability: Capability {
    // MARK: Lifecycle

    public init(
        backend: any KeychainBackend,
        authenticator: any BiometricAuthenticator
    ) {
        self.backend = backend
        self.authenticator = authenticator
    }

    // MARK: Public

    // MARK: Capability

    public var id: CapabilityID {
        .secrets
    }

    public var supportedMethods: Set<String> {
        Self.allMethods
    }

    public func call(
        method: String,
        arguments: [String: JSONValue],
        context: CapabilityCallContext
    ) async throws -> JSONValue {
        guard let pluginID = context.callerPluginID else {
            throw CapabilityError.invalidArguments(
                method: method,
                expected: "non-nil callerPluginID",
                actual: "nil"
            )
        }

        switch method {
        case "get":
            return try await self.handleGet(arguments: arguments, pluginID: pluginID, attended: context.attended)
        case "set":
            return try self.handleSet(arguments: arguments, pluginID: pluginID)
        case "delete":
            return try self.handleDelete(arguments: arguments, pluginID: pluginID)
        case "list":
            return try self.handleList(pluginID: pluginID)
        case "setBiometricRequired":
            return try self.handleSetBiometric(arguments: arguments, pluginID: pluginID)
        case "isBiometricRequired":
            return try self.handleIsBiometric(arguments: arguments, pluginID: pluginID)
        default:
            throw CapabilityError.unknownMethod(capability: .secrets, method: method)
        }
    }

    // MARK: Internal

    /// Closed set so the broker's `supportedMethods` check stays
    /// authoritative. Keep in sync with the `switch` in `call`.
    static let allMethods: Set<String> = [
        "get",
        "set",
        "delete",
        "list",
        "setBiometricRequired",
        "isBiometricRequired",
    ]

    static func valueKey(pluginID: String, name: String) -> String {
        "\(pluginID)::\(name)"
    }

    static func biometricFlagKey(pluginID: String, name: String) -> String {
        "__bio.\(pluginID)::\(name)"
    }

    static func valueKeyPrefix(pluginID: String) -> String {
        "\(pluginID)::"
    }

    // MARK: Private

    private let backend: any KeychainBackend
    private let authenticator: any BiometricAuthenticator

    private static func requireStringArg(
        _ key: String,
        from arguments: [String: JSONValue],
        method: String
    ) throws -> String {
        guard let value = arguments[key] else {
            throw CapabilityError.invalidArguments(
                method: method,
                expected: "argument '\(key)' of type string",
                actual: "missing"
            )
        }
        guard case let .string(string) = value else {
            throw CapabilityError.invalidArguments(
                method: method,
                expected: "argument '\(key)' of type string",
                actual: String(describing: value)
            )
        }
        return string
    }

    private static func requireBoolArg(
        _ key: String,
        from arguments: [String: JSONValue],
        method: String
    ) throws -> Bool {
        guard let value = arguments[key] else {
            throw CapabilityError.invalidArguments(
                method: method,
                expected: "argument '\(key)' of type bool",
                actual: "missing"
            )
        }
        guard case let .bool(flag) = value else {
            throw CapabilityError.invalidArguments(
                method: method,
                expected: "argument '\(key)' of type bool",
                actual: String(describing: value)
            )
        }
        return flag
    }

    // MARK: - Method handlers

    private func handleGet(
        arguments: [String: JSONValue],
        pluginID: String,
        attended: Bool
    ) async throws -> JSONValue {
        let name = try Self.requireStringArg("name", from: arguments, method: "get")
        let storeKey = Self.valueKey(pluginID: pluginID, name: name)
        let biometricKey = Self.biometricFlagKey(pluginID: pluginID, name: name)

        let biometricRequired: Bool
        do {
            biometricRequired = try self.backend.get(biometricKey) != nil
        } catch {
            throw CapabilityError.underlying(String(describing: error))
        }

        if biometricRequired {
            // Unattended runs can't prompt. Per the design we
            // degrade to nil rather than throwing, so a
            // background-fired workflow doesn't crash on a
            // biometric-gated read.
            guard attended else {
                return .null
            }
            let approved = await self.authenticator.authenticate(
                reason: "Unlock '\(name)' for \(pluginID)"
            )
            guard approved else {
                return .null
            }
        }

        let value: String?
        do {
            value = try self.backend.get(storeKey)
        } catch {
            throw CapabilityError.underlying(String(describing: error))
        }
        return value.map(JSONValue.string) ?? .null
    }

    private func handleSet(
        arguments: [String: JSONValue],
        pluginID: String
    ) throws -> JSONValue {
        let name = try Self.requireStringArg("name", from: arguments, method: "set")
        let value = try Self.requireStringArg("value", from: arguments, method: "set")
        let storeKey = Self.valueKey(pluginID: pluginID, name: name)
        do {
            try self.backend.set(value, forKey: storeKey)
        } catch {
            throw CapabilityError.underlying(String(describing: error))
        }
        return .bool(true)
    }

    private func handleDelete(
        arguments: [String: JSONValue],
        pluginID: String
    ) throws -> JSONValue {
        let name = try Self.requireStringArg("name", from: arguments, method: "delete")
        let storeKey = Self.valueKey(pluginID: pluginID, name: name)
        let biometricKey = Self.biometricFlagKey(pluginID: pluginID, name: name)
        do {
            try self.backend.delete(storeKey)
            try self.backend.delete(biometricKey)
        } catch {
            throw CapabilityError.underlying(String(describing: error))
        }
        return .bool(true)
    }

    private func handleList(pluginID: String) throws -> JSONValue {
        let prefix = Self.valueKeyPrefix(pluginID: pluginID)
        let keys: [String]
        do {
            keys = try self.backend.list(withPrefix: prefix)
        } catch {
            throw CapabilityError.underlying(String(describing: error))
        }
        // Strip the prefix so callers see the user-facing key
        // names (`OPENAI_API_KEY`), not the partitioned storage
        // keys (`so.aria.x::OPENAI_API_KEY`).
        let userNames = keys.map { String($0.dropFirst(prefix.count)) }
        return .array(userNames.map(JSONValue.string))
    }

    private func handleSetBiometric(
        arguments: [String: JSONValue],
        pluginID: String
    ) throws -> JSONValue {
        let name = try Self.requireStringArg("name", from: arguments, method: "setBiometricRequired")
        let required = try Self.requireBoolArg("required", from: arguments, method: "setBiometricRequired")
        let biometricKey = Self.biometricFlagKey(pluginID: pluginID, name: name)
        do {
            if required {
                try self.backend.set("1", forKey: biometricKey)
            } else {
                try self.backend.delete(biometricKey)
            }
        } catch {
            throw CapabilityError.underlying(String(describing: error))
        }
        return .bool(true)
    }

    private func handleIsBiometric(
        arguments: [String: JSONValue],
        pluginID: String
    ) throws -> JSONValue {
        let name = try Self.requireStringArg("name", from: arguments, method: "isBiometricRequired")
        let biometricKey = Self.biometricFlagKey(pluginID: pluginID, name: name)
        let present: Bool
        do {
            present = try self.backend.get(biometricKey) != nil
        } catch {
            throw CapabilityError.underlying(String(describing: error))
        }
        return .bool(present)
    }
}
