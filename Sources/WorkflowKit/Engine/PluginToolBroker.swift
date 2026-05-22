import Aria
import Foundation
#if canImport(JavaScriptCore)
    import AriaToolsJS
#endif

// MARK: - PluginToolBroker

/// Resolves and invokes a JS plugin tool by id. The compiler
/// uses this to lower a `PluginToolStep` into a `StateGraph`
/// node without depending on `AriaToolsJS` concrete types
/// directly — host apps wire the real implementation via
/// `JSPluginToolBroker`, tests can stub it freely.
public protocol PluginToolBroker: Sendable {
    func invoke(pluginID: String, input: JSONValue) async throws -> JSONValue
}

// MARK: - JSPluginToolBroker

#if canImport(JavaScriptCore)
    /// `PluginToolBroker` backed by an `AriaToolsJS.JSToolProvider`.
    /// Looks up the loaded tool by manifest id on the main actor
    /// (the provider is `@MainActor`-isolated) and forwards the
    /// invocation to its `LoadedTool.invoke(_:)`. Unknown plugin
    /// ids surface as `WorkflowEngineError.unknownPluginTool`.
    public final class JSPluginToolBroker: PluginToolBroker, @unchecked Sendable {
        // MARK: Lifecycle

        public init(provider: JSToolProvider) {
            self.provider = provider
        }

        // MARK: Public

        public func invoke(pluginID: String, input: JSONValue) async throws -> JSONValue {
            // Provider state is `@MainActor`-isolated — hop the
            // tool lookup over before kicking off the (async, not
            // actor-isolated) JS call.
            let tool: JSToolProvider.LoadedTool? = await MainActor.run {
                self.provider.loaded.first(where: { $0.bundle.id == pluginID })
            }
            guard let tool else {
                throw WorkflowEngineError.unknownPluginTool(pluginID)
            }
            return try await tool.invoke(input)
        }

        // MARK: Private

        private let provider: JSToolProvider
    }
#endif
