#if canImport(MLXLMCommon)
    import Aria
    import Foundation
    import MLXLMCommon

    // MARK: - MLXToolBridge

    /// Convert Aria's `AnyTool` (with `JSONSchema` parameters) into the
    /// OpenAI-style `ToolSpec` dictionary `MLXLMCommon` expects, and the
    /// other direction (MLX `ToolCall` back into Aria `ToolCall` +
    /// arguments) when the model emits a structured call.
    enum MLXToolBridge {
        // MARK: Internal

        // MARK: - Aria → MLX

        /// Build the `[ToolSpec]` array passed via
        /// `UserInput(... tools: ...)`. `nil` when the input list is
        /// empty so we skip threading tools when there's nothing to send.
        static func toolSpecs(from tools: [AnyTool]) -> [ToolSpec]? {
            guard !tools.isEmpty else {
                return nil
            }
            return tools.map { Self.toolSpec(from: $0.definition) }
        }

        /// `ToolDefinition`-flavoured overload. The agent layer reaches
        /// `LLMProvider` through the protocol method `stream(messages:
        /// tools: options:)` whose `tools` parameter is `[ToolDefinition]`,
        /// not `[AnyTool]`. That's all MLX needs — only the schema is
        /// forwarded into the chat template; the agent layer keeps the
        /// invocation closures and runs the tool once we yield a
        /// `toolCallStart` / `toolCallEnd` pair.
        static func toolSpecs(fromDefinitions definitions: [ToolDefinition]) -> [ToolSpec]? {
            guard !definitions.isEmpty else {
                return nil
            }
            return definitions.map(self.toolSpec(from:))
        }

        // MARK: - MLX → Aria

        /// Convert an mlx-swift-lm `ToolCall` (with structured
        /// arguments) into Aria's `ToolCall`. The id is synthesized —
        /// mlx-swift-lm doesn't surface one — using a UUID; the agent
        /// loop only needs id stability within a single stream.
        static func ariaToolCall(from call: MLXLMCommon.ToolCall) -> Aria.ToolCall {
            let arguments = JSONValue.object(call.function.arguments.mapValues(Self.ariaJSONValue(from:)))
            return Aria.ToolCall(
                id: UUID().uuidString,
                name: call.function.name,
                arguments: arguments
            )
        }

        // MARK: Private

        /// One `ToolSpec` for one Aria tool. Shape matches the OpenAI
        /// function-calling JSON schema; mlx-swift-lm's chat-template
        /// renderer maps it onto the model-specific format.
        private static func toolSpec(from definition: ToolDefinition) -> ToolSpec {
            let parameters = Self.parametersDictionary(from: definition.inputSchema)
            let function: [String: any Sendable] = [
                "name": definition.name,
                "description": definition.description,
                "parameters": parameters,
            ]
            return [
                "type": "function",
                "function": function,
            ]
        }

        /// Render Aria's `JSONSchema` for the tool's `Input` into the
        /// `[String: Any]` dictionary an OpenAI-style tool schema
        /// expects. Only the cases we actually emit at the top level
        /// are translated; complex unions fall back to the canonical
        /// JSON encoding.
        private static func parametersDictionary(from schema: JSONSchema) -> [String: any Sendable] {
            switch schema {
            case let .object(properties, required, description, _):
                var props: [String: any Sendable] = [:]
                for (key, value) in properties {
                    props[key] = Self.schemaDictionary(from: value)
                }
                var result: [String: any Sendable] = [
                    "type": "object",
                    "properties": props,
                    "required": required,
                ]
                if let description {
                    result["description"] = description
                }
                return result
            default:
                return self.schemaDictionary(from: schema)
            }
        }

        private static func schemaDictionary(from schema: JSONSchema) -> [String: any Sendable] {
            switch schema {
            case let .string(description, enumValues):
                var dict: [String: any Sendable] = ["type": "string"]
                if let description {
                    dict["description"] = description
                }
                if let enumValues {
                    dict["enum"] = enumValues
                }
                return dict
            case .number:
                return ["type": "number"]
            case .integer:
                return ["type": "integer"]
            case .boolean:
                return ["type": "boolean"]
            case let .array(items, _):
                return ["type": "array", "items": Self.schemaDictionary(from: items)]
            case let .object(properties, required, description, _):
                var props: [String: any Sendable] = [:]
                for (key, value) in properties {
                    props[key] = Self.schemaDictionary(from: value)
                }
                var dict: [String: any Sendable] = [
                    "type": "object",
                    "properties": props,
                    "required": required,
                ]
                if let description {
                    dict["description"] = description
                }
                return dict
            case .null:
                return ["type": "null"]
            case let .oneOf(schemas), let .anyOf(schemas), let .allOf(schemas):
                return ["type": "object", "anyOf": schemas.map(Self.schemaDictionary(from:))]
            }
        }

        private static func ariaJSONValue(from value: MLXLMCommon.JSONValue) -> Aria.JSONValue {
            switch value {
            case .null: .null
            case let .bool(bool): .bool(bool)
            case let .int(int): .integer(Int64(int))
            case let .double(double): .number(double)
            case let .string(string): .string(string)
            case let .array(values): .array(values.map(Self.ariaJSONValue(from:)))
            case let .object(values): .object(values.mapValues(Self.ariaJSONValue(from:)))
            }
        }
    }
#endif
