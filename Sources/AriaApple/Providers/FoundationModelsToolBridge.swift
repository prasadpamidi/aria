#if canImport(FoundationModels)
    import Aria
    import Foundation
    import FoundationModels
    import os

    // MARK: - Schema translator

    /// Convert Aria's `JSONSchema` into FoundationModels'
    /// `DynamicGenerationSchema` so a tool defined at runtime can be
    /// advertised to a `LanguageModelSession`.
    @available(iOS 26.0, macOS 26.0, *)
    enum FoundationModelsSchemaTranslator {
        // MARK: Internal

        /// Convert a top-level schema (used as a tool's parameter schema)
        /// into a `GenerationSchema`. The schema is rooted in a
        /// `DynamicGenerationSchema` for the object/primitive/array case.
        static func generationSchema(
            forTool name: String,
            description: String?,
            inputSchema: JSONSchema
        ) throws -> GenerationSchema {
            let root = self.dynamicSchema(
                from: inputSchema,
                fallbackName: name,
                description: description
            )
            return try GenerationSchema(root: root, dependencies: [])
        }

        /// Recursive translator. `fallbackName` is used when an object
        /// schema does not name itself; FoundationModels requires every
        /// object schema have a name.
        static func dynamicSchema(
            from schema: JSONSchema,
            fallbackName: String,
            description: String? = nil
        ) -> DynamicGenerationSchema {
            switch schema {
            case let .string(_, enumValues):
                self.stringSchema(
                    fallbackName: fallbackName,
                    description: description,
                    enumValues: enumValues
                )
            case .number: DynamicGenerationSchema(type: Double.self)
            case .integer: DynamicGenerationSchema(type: Int.self)
            case .boolean: DynamicGenerationSchema(type: Bool.self)
            case let .array(items, _):
                DynamicGenerationSchema(
                    arrayOf: self.dynamicSchema(from: items, fallbackName: "\(fallbackName)Item")
                )
            case let .object(properties, required, objectDescription, _):
                self.objectSchema(
                    fallbackName: fallbackName,
                    properties: properties,
                    required: required,
                    description: objectDescription ?? description
                )
            case let .oneOf(schemas), let .anyOf(schemas):
                self.unionSchema(
                    fallbackName: fallbackName,
                    description: description,
                    choices: schemas
                )
            case let .allOf(schemas):
                // FoundationModels has no native `allOf`; collapse to the
                // first sub-schema. Tools that need intersection types
                // should use a single object schema instead.
                schemas.first.map { self.dynamicSchema(from: $0, fallbackName: fallbackName) }
                    ?? DynamicGenerationSchema(type: String.self)
            case .null:
                DynamicGenerationSchema(type: String.self)
            }
        }

        // MARK: Private

        private static func stringSchema(
            fallbackName: String,
            description: String?,
            enumValues: [String]?
        ) -> DynamicGenerationSchema {
            if let enumValues, !enumValues.isEmpty {
                return DynamicGenerationSchema(
                    name: fallbackName,
                    description: description,
                    anyOf: enumValues
                )
            }
            return DynamicGenerationSchema(type: String.self)
        }

        private static func objectSchema(
            fallbackName: String,
            properties: [String: JSONSchema],
            required: [String],
            description: String?
        ) -> DynamicGenerationSchema {
            let dynamicProps = properties.map { key, value in
                DynamicGenerationSchema.Property(
                    name: key,
                    schema: self.dynamicSchema(
                        from: value,
                        fallbackName: "\(fallbackName)_\(key)"
                    ),
                    isOptional: !required.contains(key)
                )
            }
            return DynamicGenerationSchema(
                name: fallbackName,
                description: description,
                properties: dynamicProps
            )
        }

        private static func unionSchema(
            fallbackName: String,
            description: String?,
            choices: [JSONSchema]
        ) -> DynamicGenerationSchema {
            let dynamicChoices = choices.enumerated().map { index, sub in
                self.dynamicSchema(
                    from: sub,
                    fallbackName: "\(fallbackName)_choice_\(index)"
                )
            }
            return DynamicGenerationSchema(
                name: fallbackName,
                description: description,
                anyOf: dynamicChoices
            )
        }
    }

    // MARK: - AriaBridgeTool

    /// Bridges Aria's `AnyTool` to `FoundationModels.Tool` so tools
    /// defined with Aria's runtime `JSONSchema` are usable inside a
    /// `LanguageModelSession`.
    ///
    /// When the model invokes the tool, the bridge:
    /// 1. extracts JSON arguments from the `GeneratedContent`,
    /// 2. dispatches to Aria's `AnyTool.invoke`,
    /// 3. emits a `ProviderEvent.toolCallExecuted` so the agent layer
    ///    surfaces equivalent `AgentEvent`s to consumers,
    /// 4. returns the JSON-encoded result string back to the session
    ///    for the model to incorporate into its response.
    @available(iOS 26.0, macOS 26.0, *)
    struct AriaBridgeTool: FoundationModels.Tool {
        // MARK: Lifecycle

        init(
            ariaTool: AnyTool,
            yieldEvent: @escaping @Sendable (ProviderEvent) -> Void
        ) throws {
            self.ariaTool = ariaTool
            self.yieldEvent = yieldEvent
            self.name = ariaTool.definition.name
            self.description = ariaTool.definition.description
            self.parameters = try FoundationModelsSchemaTranslator.generationSchema(
                forTool: ariaTool.definition.name,
                description: ariaTool.definition.description,
                inputSchema: ariaTool.definition.inputSchema
            )
        }

        // MARK: Internal

        // MARK: - FoundationModels.Tool requirements

        typealias Arguments = GeneratedContent
        typealias Output = String

        let name: String
        let description: String
        let parameters: GenerationSchema

        /// Hide the schema from the textual instructions FoundationModels
        /// builds for the model. The default (true) caused the system
        /// model to mimic the rendered "ToolName: arguments" format in
        /// its responses (writing "Current_time: 10:00 AM" instead of
        /// invoking the tool). With this off, the schema lives only in
        /// the runtime tool registration; the model is steered to invoke
        /// rather than narrate.
        var includesSchemaInInstructions: Bool {
            false
        }

        func call(arguments: GeneratedContent) async throws -> String {
            // Diagnostic: confirms the bridge is actually reached when
            // FoundationModels decides to call this tool. Visible in the
            // Xcode debug console under the "FoundationModelsBridge"
            // category.
            Self.logger.debug("AriaBridgeTool.call invoked: name=\(self.name, privacy: .public)")
            let argsValue = try Self.decodeArguments(from: arguments)
            // FoundationModels' `GenerationID` does not surface a stable
            // string form, so we mint a UUID per call. The id only needs
            // to correlate the agent's start/end events with the result.
            let callId = UUID().uuidString
            let toolCall = ToolCall(
                id: callId,
                name: self.name,
                arguments: argsValue
            )
            let context = ToolContext(runId: UUID())
            let started = ContinuousClock.now

            do {
                let resultValue = try await self.ariaTool.invoke(argsValue, context)
                let duration = ContinuousClock.now - started
                let result = ToolExecutionResult(
                    output: resultValue,
                    isError: false,
                    duration: duration
                )
                self.yieldEvent(.toolCallExecuted(call: toolCall, result: result))
                return Self.renderForModel(resultValue)
            } catch {
                let duration = ContinuousClock.now - started
                let errorMessage = String(describing: error)
                let errorResult = ToolExecutionResult(
                    output: .object(["error": .string(errorMessage)]),
                    isError: true,
                    duration: duration
                )
                self.yieldEvent(.toolCallExecuted(call: toolCall, result: errorResult))
                return "{\"error\": \(JSONValue.string(errorMessage).canonicalString)}"
            }
        }

        // MARK: Private

        private static let logger = Logger(
            subsystem: "com.aria.AriaApple",
            category: "FoundationModelsBridge"
        )

        // MARK: - Aria-side state

        private let ariaTool: AnyTool
        private let yieldEvent: @Sendable (ProviderEvent) -> Void

        // MARK: - Helpers

        private static func decodeArguments(
            from generated: GeneratedContent
        ) throws -> JSONValue {
            let json = generated.jsonString
            let data = Data(json.utf8)
            return try JSONDecoder().decode(JSONValue.self, from: data)
        }

        private static func renderForModel(_ value: JSONValue) -> String {
            guard let data = try? value.canonicalData(),
                  let string = String(bytes: data, encoding: .utf8) else {
                return "{}"
            }
            return string
        }
    }

    // MARK: - JSONValue convenience for inline JSON

    extension JSONValue {
        /// Render this value as a canonical JSON string. Used by the
        /// bridge to format error payloads inline.
        fileprivate var canonicalString: String {
            guard let data = try? self.canonicalData(),
                  let string = String(bytes: data, encoding: .utf8) else {
                return "null"
            }
            return string
        }
    }

#endif
