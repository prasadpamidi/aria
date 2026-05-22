import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// MARK: - ServerLLMProviderResolver

/// Closure injected into `WorkflowCompiler` that turns a
/// server-provider id (from `LLMStep.serverProviderID`) into a
/// configured `WorkflowLLMProvider` ready to take a prompt. The
/// app constructs the closure with read access to its
/// `ServerProviderStore` + `CredentialStore` so the engine never
/// touches UserDefaults / Keychain directly.
///
/// Returning `nil` makes the LLM step fall back to the compiler's
/// default provider (typically on-device FoundationModels). The
/// editor flags steps whose server provider has been deleted, so
/// most nil-returns indicate a misconfiguration the user has
/// already been warned about.
public typealias ServerLLMProviderResolver = @Sendable (UUID) async -> (any WorkflowLLMProvider)?
