import Foundation

// MARK: - BiometricAuthenticator

/// Injection seam for Face ID / Touch ID prompts. Production
/// `SecretsCapability` uses `LocalAuthAuthenticator` which wraps
/// `LAContext.evaluatePolicy`; tests use a deterministic stub.
///
/// Returns `true` on a successful prompt, `false` when the user
/// cancels or fails. The capability layer converts that into a
/// `nil` read result so unattended Siri/widget invocations don't
/// crash on key access.
public protocol BiometricAuthenticator: Sendable {
    /// Prompt with the given reason. Implementations must be safe
    /// to call from any actor — production calls
    /// `LAContext.evaluatePolicy` which is async-safe; the stub
    /// just returns the canned answer.
    func authenticate(reason: String) async -> Bool
}

// MARK: - AlwaysApproveAuthenticator

/// Test/preview stub that always approves. Combined with the
/// in-memory keychain backend, gives tests a deterministic
/// "biometric is enabled and the prompt always succeeds" path.
public struct AlwaysApproveAuthenticator: BiometricAuthenticator {
    // MARK: Lifecycle

    public init() { }

    // MARK: Public

    public func authenticate(reason _: String) async -> Bool {
        true
    }
}

// MARK: - AlwaysDenyAuthenticator

/// Test/preview stub that always denies. Useful for asserting
/// the "user cancelled biometric prompt → nil read" code path.
public struct AlwaysDenyAuthenticator: BiometricAuthenticator {
    // MARK: Lifecycle

    public init() { }

    // MARK: Public

    public func authenticate(reason _: String) async -> Bool {
        false
    }
}

// MARK: - LocalAuthAuthenticator

#if canImport(LocalAuthentication)
    import LocalAuthentication

    /// Production authenticator. Uses
    /// `LAPolicy.deviceOwnerAuthenticationWithBiometrics` so the
    /// fallback (passcode) is only offered if the device doesn't
    /// support biometrics at all. We deliberately don't fall back
    /// to passcode when biometrics fail — for "require Face ID"
    /// keys, the user explicitly opted into a biometric gate.
    public struct LocalAuthAuthenticator: BiometricAuthenticator {
        // MARK: Lifecycle

        public init() { }

        // MARK: Public

        public func authenticate(reason: String) async -> Bool {
            let context = LAContext()
            var error: NSError?
            guard context.canEvaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                error: &error
            ) else {
                return false
            }

            return await withCheckedContinuation { continuation in
                context.evaluatePolicy(
                    .deviceOwnerAuthenticationWithBiometrics,
                    localizedReason: reason
                ) { success, _ in
                    continuation.resume(returning: success)
                }
            }
        }
    }
#endif
