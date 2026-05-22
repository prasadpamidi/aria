import Foundation

// MARK: - MLXLLMProviderResolver

/// Closure injected into `WorkflowCompiler` that turns an MLX
/// model id (from `LLMStep.mlxModelID`) into a configured
/// `WorkflowLLMProvider` ready to take a prompt. The app
/// constructs the closure with read access to its
/// `MLXModelManager` so the engine never imports `AriaMLX`
/// directly — `WorkflowKit` stays platform-agnostic.
///
/// Returning `nil` falls through to the compiler's default
/// provider (Apple Intelligence). Legitimate nil-returns include:
///   1. The named MLX model isn't in the catalog.
///   2. The model is in the catalog but hasn't been downloaded.
///   3. `AriaMLX` isn't linked in this build (test harness).
/// The editor flags steps that point at an absent MLX model, so
/// by the time a run reaches the resolver the user has been
/// warned about the fallback.
public typealias MLXLLMProviderResolver = @Sendable (String) async -> (any WorkflowLLMProvider)?
