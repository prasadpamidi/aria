import Foundation

// MARK: - KeychainBackend

/// Injection seam for the real Keychain. Production
/// `SecretsCapability` uses `SecurityFrameworkKeychain`; tests
/// use `InMemoryKeychainBackend` so the test runner never needs
/// keychain entitlements and there's no residue between runs.
///
/// All operations are throwing — the underlying Security
/// framework calls can fail in ways the capability layer wants
/// to surface (not just nil-return).
public protocol KeychainBackend: Sendable {
    /// Store a value. Replaces any existing value for `key`.
    func set(_ value: String, forKey key: String) throws

    /// Read a value. Returns `nil` for missing keys; throws for
    /// other failures (entitlement issues, lock state, etc.).
    func get(_ key: String) throws -> String?

    /// Delete a key. No-op on missing.
    func delete(_ key: String) throws

    /// List every key in this backend with the given prefix.
    /// The capability layer uses this to enumerate one plugin's
    /// stored keys without leaking other plugins' names.
    func list(withPrefix prefix: String) throws -> [String]
}

// MARK: - InMemoryKeychainBackend

/// Thread-safe dictionary-backed keychain stand-in for tests +
/// previews. Not used in production code paths — the production
/// `SecretsCapability` always constructs `SecurityFrameworkKeychain`.
public final class InMemoryKeychainBackend: KeychainBackend, @unchecked Sendable {
    // MARK: Lifecycle

    public init() { }

    // MARK: Public

    public func set(_ value: String, forKey key: String) throws {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.storage[key] = value
    }

    public func get(_ key: String) throws -> String? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.storage[key]
    }

    public func delete(_ key: String) throws {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.storage.removeValue(forKey: key)
    }

    public func list(withPrefix prefix: String) throws -> [String] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.storage.keys
            .filter { $0.hasPrefix(prefix) }
            .sorted()
    }

    // MARK: Private

    private let lock = NSLock()
    private var storage: [String: String] = [:]
}

// MARK: - SecurityFrameworkKeychain

#if canImport(Security)
    import Security

    /// Real Keychain backend. Items are stored as `kSecClassGenericPassword`
    /// scoped by `kSecAttrService` to a fixed service name so this
    /// app's items never collide with other apps in the same access
    /// group. Per-plugin partitioning is handled by the
    /// `SecretsCapability` (it composes the `account` key as
    /// `pluginID::keyName`) — this backend deliberately doesn't
    /// know about that layout.
    public struct SecurityFrameworkKeychain: KeychainBackend {
        // MARK: Lifecycle

        public init(service: String = "so.aria.workflowkit.secrets") {
            self.service = service
        }

        // MARK: Public

        public func set(_ value: String, forKey key: String) throws {
            guard let data = value.data(using: .utf8) else {
                throw SecretsBackendError.invalidValueEncoding
            }

            // Try update first; fall back to add. Avoids the
            // duplicate-item error path of plain SecItemAdd when
            // the user is rotating an existing key.
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: self.service,
                kSecAttrAccount as String: key,
            ]
            let updateAttrs: [String: Any] = [
                kSecValueData as String: data,
            ]
            let updateStatus = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)

            if updateStatus == errSecSuccess {
                return
            }
            if updateStatus != errSecItemNotFound {
                throw SecretsBackendError.osStatus(updateStatus)
            }

            var addAttrs = query
            addAttrs[kSecValueData as String] = data
            addAttrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(addAttrs as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw SecretsBackendError.osStatus(addStatus)
            }
        }

        public func get(_ key: String) throws -> String? {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: self.service,
                kSecAttrAccount as String: key,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            switch status {
            case errSecSuccess:
                guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
                    return nil
                }
                return value
            case errSecItemNotFound:
                return nil
            default:
                throw SecretsBackendError.osStatus(status)
            }
        }

        public func delete(_ key: String) throws {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: self.service,
                kSecAttrAccount as String: key,
            ]
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess, status != errSecItemNotFound {
                throw SecretsBackendError.osStatus(status)
            }
        }

        public func list(withPrefix prefix: String) throws -> [String] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: self.service,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitAll,
            ]
            var items: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &items)
            switch status {
            case errSecSuccess:
                guard let array = items as? [[String: Any]] else {
                    return []
                }
                return array
                    .compactMap { $0[kSecAttrAccount as String] as? String }
                    .filter { $0.hasPrefix(prefix) }
                    .sorted()
            case errSecItemNotFound:
                return []
            default:
                throw SecretsBackendError.osStatus(status)
            }
        }

        // MARK: Private

        private let service: String
    }
#endif

// MARK: - SecretsBackendError

public enum SecretsBackendError: Error, Sendable, Equatable {
    /// String → Data conversion failed (should never happen for
    /// UTF-8 strings; surfaced so the failure mode is explicit).
    case invalidValueEncoding
    /// Raw OSStatus from a Security framework call (only on Apple
    /// platforms).
    case osStatus(Int32)
}
