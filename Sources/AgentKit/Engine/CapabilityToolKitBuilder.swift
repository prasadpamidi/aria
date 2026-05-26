import Aria
import Foundation
import WorkflowKit

#if canImport(FoundationModels)
    import AriaApple
    import FoundationModels
#endif

// MARK: - CapabilityToolKitBuilder

/// Turns an agent's enabled native capabilities into the agent's tool
/// list. The agent analog of `MCPServerToolKitBuilder` /
/// `JSToolProvider.foundationModelsKits()` — chat never exposed native
/// capabilities (calendar, health, …) as agent tools (only workflows
/// did, through the broker), so this is the one genuinely net-new
/// engine piece.
///
/// Each `(capability, method)` becomes a `FoundationModelsToolKit`
/// pairing:
///   - an `AnyTool` (MLX / cloud providers consume the closure form),
///   - a `factory` returning a `CapabilityFMTool` so FoundationModels'
///     typed-tool router sees it too (without this the tools would be
///     invisible on the default on-device provider).
///
/// Both forms forward to `CapabilityBroker.call`, with the
/// `"avyra.builtin.agent.<id>"` caller prefix so the broker treats the
/// agent as first-party and skips per-plugin scope prompts.
public enum CapabilityToolKitBuilder {
    // MARK: Public

    // MARK: Helpers (always available)

    /// Caller id that marks an agent as first-party to the broker.
    /// Exposed so the host's proposal executor can use the same id
    /// for approved side-effect calls, keeping the audit trail
    /// consistent across the agent's own tool calls and the host's
    /// follow-up calls on approval.
    public static func callerPluginID(for agentID: UUID) -> String {
        "avyra.builtin.agent.\(agentID.uuidString)"
    }

    // MARK: Internal

    #if canImport(FoundationModels)
        @MainActor
        @available(iOS 26.0, macOS 26.0, *)
        static func makeKits(
            for definition: AgentDefinition,
            broker: CapabilityBroker,
            attended: Bool
        ) -> [FoundationModelsToolKit] {
            let caller = Self.callerPluginID(for: definition.id)
            var kits: [FoundationModelsToolKit] = []
            for capability in definition.enabledCapabilities {
                let allowed = definition.allowedMethods(for: capability)
                for method in CapabilityCatalog.methods(for: capability) {
                    if let allowed, !allowed.contains(method.name) {
                        continue
                    }
                    // HITL: under `.proposeThenConfirm`, side-effecting
                    // methods are kept OUT of the agent's surface — the
                    // agent must `propose_action` and the host executes
                    // on approval. Over-gates (ignores the specific
                    // `actions` set) rather than risk an un-gated side
                    // effect.
                    if Self.isGatedOut(method: method, policy: definition.approvalPolicy) {
                        continue
                    }
                    kits.append(Self.makeKit(
                        capability: capability,
                        method: method,
                        broker: broker,
                        callerPluginID: caller,
                        attended: attended
                    ))
                }
            }
            return kits
        }

        @MainActor
        @available(iOS 26.0, macOS 26.0, *)
        private static func makeKit(
            capability: CapabilityID,
            method: CapabilityMethod,
            broker: CapabilityBroker,
            callerPluginID: String,
            attended: Bool
        ) -> FoundationModelsToolKit {
            let toolName = Self.toolName(capability: capability, method: method.name)
            let description = Self.description(capability: capability, method: method)
            let methodName = method.name
            let definition = ToolDefinition(
                name: toolName,
                description: description,
                // Permissive object — the description carries the real
                // arg contract (same approach MCP tools use). The broker
                // + capability validate args at call time.
                inputSchema: .object(properties: [:], required: [], description: nil, additionalProperties: true),
                outputSchema: nil
            )
            return FoundationModelsToolKit(
                anyTool: AnyTool(definition: definition) { input, _ in
                    let args = Self.argsMap(from: input)
                    return try await broker.call(
                        capability: capability,
                        method: methodName,
                        arguments: args,
                        callerPluginID: callerPluginID,
                        attended: attended
                    )
                },
                factory: { yield in
                    CapabilityFMTool(
                        capability: capability,
                        method: methodName,
                        modelName: toolName,
                        description: description,
                        broker: broker,
                        callerPluginID: callerPluginID,
                        attended: attended,
                        yieldEvent: yield
                    )
                }
            )
        }
    #endif

    static func toolName(capability: CapabilityID, method: String) -> String {
        "\(capability.rawValue)_\(method)"
    }

    static func description(capability: CapabilityID, method: CapabilityMethod) -> String {
        """
        [\(capability.rawValue)] \(method.summary)

        REQUIRED ARGUMENTS (pass as a JSON object string in argumentsJSON):
        \(method.argHint)

        Always populate the keys above before calling this tool. \
        Pass "{}" only when the Arguments line literally says "No arguments."
        """
    }

    static func isGatedOut(method: CapabilityMethod, policy: ApprovalPolicy) -> Bool {
        switch policy {
        case .autonomous: false
        case .proposeThenConfirm: method.isSideEffecting
        }
    }

    /// `AnyTool.invoke` receives a `JSONValue` already shape-checked
    /// against the (permissive) input schema. Non-object inputs
    /// collapse to an empty map so the capability sees a usable
    /// `arguments` dictionary.
    static func argsMap(from input: JSONValue) -> [String: JSONValue] {
        if case let .object(map) = input {
            return map
        }
        return [:]
    }
}

#if canImport(FoundationModels)

    // MARK: - CapabilityToolArguments

    /// Shared `@Generable` arguments for every capability-as-tool.
    /// Mirrors `WorkflowToolArguments` — Swift can't synthesise a new
    /// `@Generable` per `(capability, method)` at runtime, but
    /// `FoundationModels.Tool` carries instance `name` / `description`,
    /// so one conformer vends many tools that share this `argumentsJSON`
    /// shape. The per-method arg contract lives in the description.
    @available(iOS 26.0, macOS 26.0, *)
    @Generable
    struct CapabilityToolArguments: Codable {
        @Guide(
            description: "Arguments as a JSON object string matching the Arguments line in this tool's description. Use \"{}\" when the tool takes no arguments."
        )
        var argumentsJSON: String
    }

    // MARK: - CapabilityFMTool

    /// FoundationModels-routable wrapper around one capability method.
    /// Decodes the model's `argumentsJSON`, forwards to the broker, and
    /// returns the result as text — emitting a `.toolCallExecuted`
    /// `ProviderEvent` so the run's recording surface captures the call,
    /// matching `WorkflowFMTool` / `MCPToolFMTool`.
    @available(iOS 26.0, macOS 26.0, *)
    struct CapabilityFMTool: FoundationModels.Tool {
        // MARK: Lifecycle

        init(
            capability: CapabilityID,
            method: String,
            modelName: String,
            description: String,
            broker: CapabilityBroker,
            callerPluginID: String,
            attended: Bool,
            yieldEvent: @escaping @Sendable (ProviderEvent) -> Void
        ) {
            self.capability = capability
            self.method = method
            self.name = modelName
            self.description = description
            self.broker = broker
            self.callerPluginID = callerPluginID
            self.attended = attended
            self.yieldEvent = yieldEvent
        }

        // MARK: Internal

        typealias Arguments = CapabilityToolArguments
        typealias Output = String

        let name: String
        let description: String

        func call(arguments: CapabilityToolArguments) async throws -> String {
            let callId = UUID().uuidString
            let started = ContinuousClock.now
            let args = Self.parse(arguments.argumentsJSON)
            let toolCall = ToolCall(id: callId, name: self.name, arguments: .object(args))
            do {
                let result = try await self.broker.call(
                    capability: self.capability,
                    method: self.method,
                    arguments: args,
                    callerPluginID: self.callerPluginID,
                    attended: self.attended
                )
                self.yieldEvent(.toolCallExecuted(
                    call: toolCall,
                    result: ToolExecutionResult(
                        output: result,
                        isError: false,
                        duration: ContinuousClock.now - started
                    )
                ))
                return Self.render(result)
            } catch {
                let errorJSON = JSONValue.object(["error": .string(error.localizedDescription)])
                self.yieldEvent(.toolCallExecuted(
                    call: toolCall,
                    result: ToolExecutionResult(
                        output: errorJSON,
                        isError: true,
                        duration: ContinuousClock.now - started
                    )
                ))
                return "Error: \(error.localizedDescription)"
            }
        }

        // MARK: Private

        private let capability: CapabilityID
        private let method: String
        private let broker: CapabilityBroker
        private let callerPluginID: String
        private let attended: Bool
        private let yieldEvent: @Sendable (ProviderEvent) -> Void

        private static func parse(_ raw: String) -> [String: JSONValue] {
            guard let data = raw.data(using: .utf8),
                  let value = try? JSONDecoder().decode(JSONValue.self, from: data),
                  case let .object(map) = value else {
                return [:]
            }
            return map
        }

        private static func render(_ value: JSONValue) -> String {
            guard let data = try? value.canonicalData(),
                  let string = String(bytes: data, encoding: .utf8) else {
                return "{}"
            }
            return string
        }
    }

#endif
