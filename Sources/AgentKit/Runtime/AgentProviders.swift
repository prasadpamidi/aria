import Aria
import Foundation

#if canImport(FoundationModels)
    import AriaApple
    import FoundationModels

    // MARK: - Injected closures

    /// Supplies the host's app-specific tools (MCP / workflow / plugin /
    /// skill-load) for an agent, as `FoundationModelsToolKit`s.
    @available(iOS 26.0, macOS 26.0, *)
    public typealias AgentExtraToolsProvider = @MainActor @Sendable (AgentDefinition) -> [FoundationModelsToolKit]

    /// Supplies the host's LLM routing for an agent run.
    @available(iOS 26.0, macOS 26.0, *)
    public typealias AgentProviderFactory = @MainActor @Sendable (
        _ definition: AgentDefinition,
        _ typedFactories: [FoundationModelsToolFactory],
        _ instructions: String
    ) -> any LLMProvider

    // MARK: - AgentProviders

    /// Ready-made provider factories for `AgentRuntime.boot(makeProvider:)`.
    /// Consumers that only need the default on-device model can pass
    /// `AgentProviders.foundationModelsOnly`; apps with server / MLX
    /// routing supply their own closure instead.
    @available(iOS 26.0, macOS 26.0, *)
    public enum AgentProviders {
        @MainActor
        public static func foundationModelsOnly(
            _: AgentDefinition,
            _ typedFactories: [FoundationModelsToolFactory],
            _: String
        ) -> any LLMProvider {
            FoundationModelsProvider(typedTools: typedFactories)
        }
    }

#endif
