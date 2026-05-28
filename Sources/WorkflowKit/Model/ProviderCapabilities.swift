import Foundation

// MARK: - WorkflowProviderCapabilities

/// Declarative description of what a `WorkflowLLMProvider`
/// supports. Read by `WorkflowCompiler` at pre-flight to validate
/// step requirements (modalities, streaming, mid-turn tools, schema
/// ids) before any tokens flow. Mismatches surface as typed
/// `WorkflowEngineError.providerCapabilityMissing(...)` rather than
/// silent degraded output.
///
/// Conservative defaults so existing providers compile unchanged on
/// the 0.1.x → 0.2.x upgrade — every flag is `false` / empty / nil
/// unless the provider opts in.
public struct WorkflowProviderCapabilities: Sendable, Equatable, Hashable {
    // MARK: Lifecycle

    public init(
        supportsStructuredOutput: Bool = false,
        supportsStreamingStructured: Bool = false,
        supportsMidTurnTools: Bool = false,
        supportedModalities: Set<ContentModality> = [.text],
        supportsCancellation: Bool = true,
        maxContextTokens: Int? = nil,
        maxOutputTokens: Int? = nil
    ) {
        self.supportsStructuredOutput = supportsStructuredOutput
        self.supportsStreamingStructured = supportsStreamingStructured
        self.supportsMidTurnTools = supportsMidTurnTools
        self.supportedModalities = supportedModalities
        self.supportsCancellation = supportsCancellation
        self.maxContextTokens = maxContextTokens
        self.maxOutputTokens = maxOutputTokens
    }

    // MARK: Public

    /// The default capability set inherited by providers that don't
    /// override `capabilities` — conservative on purpose so an
    /// un-updated provider can't accidentally claim more than it
    /// supports.
    public static let conservative = WorkflowProviderCapabilities()

    /// Schema-constrained decoding (FoundationModels typed respond,
    /// OpenAI `response_format=json_schema`, Anthropic tool-use mode).
    /// `false` providers fall through to the default text + lenient
    /// JSON parse path in `generateStructured`.
    public let supportsStructuredOutput: Bool

    /// Incremental snapshots of in-progress structured generation.
    /// When `false`, callers that opt into streaming receive a
    /// single terminal yield rather than per-token deltas (degrades
    /// gracefully — same final result, just less granular UI).
    public let supportsStreamingStructured: Bool

    /// Provider drives an agent loop with mid-turn tool calls and
    /// returns the final answer once the loop terminates. `false`
    /// means workflows must pre-fetch tool data via
    /// `CapabilityStep` / `PluginToolStep` / `MCPToolStep` upstream
    /// of the LLM step rather than expecting the model to pick.
    public let supportsMidTurnTools: Bool

    /// Modalities the provider accepts in a single request. Always
    /// includes `.text`; providers add `.image`, `.audio`, `.file`,
    /// `.video` as their underlying model permits. The compiler
    /// validates that an `LLMStep`'s `attachmentBindings` reference
    /// only modalities the bound provider supports.
    public let supportedModalities: Set<ContentModality>

    /// Whether the provider honours Swift `Task` cancellation
    /// propagated through `async` boundaries. `true` is the
    /// common case; `false` warns the runner that a cancelled
    /// workflow run may still complete a final in-flight call.
    public let supportsCancellation: Bool

    /// Hard caps the provider advertises. `nil` = unknown / no
    /// declared cap. Used by budget enforcement (P2-9) and by
    /// the compiler to flag obviously-oversized prompts early.
    public let maxContextTokens: Int?
    public let maxOutputTokens: Int?

    /// Convenience for `[.text]` callers — most providers want this
    /// plus a few opt-ins rather than reconstructing the full set.
    public func with(
        structuredOutput: Bool? = nil,
        streamingStructured: Bool? = nil,
        midTurnTools: Bool? = nil,
        modalities: Set<ContentModality>? = nil,
        cancellation: Bool? = nil,
        maxContextTokens: Int?? = nil,
        maxOutputTokens: Int?? = nil
    ) -> WorkflowProviderCapabilities {
        WorkflowProviderCapabilities(
            supportsStructuredOutput: structuredOutput ?? self.supportsStructuredOutput,
            supportsStreamingStructured: streamingStructured ?? self.supportsStreamingStructured,
            supportsMidTurnTools: midTurnTools ?? self.supportsMidTurnTools,
            supportedModalities: modalities ?? self.supportedModalities,
            supportsCancellation: cancellation ?? self.supportsCancellation,
            maxContextTokens: maxContextTokens ?? self.maxContextTokens,
            maxOutputTokens: maxOutputTokens ?? self.maxOutputTokens
        )
    }
}

// MARK: - ContentModality

/// Input/output modality a provider accepts. Drives the
/// compile-time validation that prevents a vision step from being
/// dispatched to a text-only provider.
public enum ContentModality: String, Codable, Sendable, Hashable, CaseIterable {
    case text
    case image
    case audio
    case file
    case video
}
