#if canImport(MLXLMCommon)
    import Aria
    import CoreImage
    import Foundation
    import MLXLMCommon
    import os

    // MARK: - MLXProvider

    // swiftlint:disable type_body_length

    /// `LLMProvider` backed by MLX (`mlx-swift-lm`). Streams from a
    /// pre-loaded `ModelContainer` cached in an `MLXModelStore`.
    ///
    /// One `MLXProvider` is bound to a single Hugging Face model id at
    /// construction time. To switch models per conversation, hold a
    /// shared `MLXModelStore` and instantiate a new provider for each
    /// model — the store ensures the underlying weights are loaded once
    /// and reused across providers.
    ///
    /// Tools registered via the agent layer are forwarded to the chat
    /// template as OpenAI-style `ToolSpec`s (see `MLXToolBridge`). When
    /// the provider's bound capabilities advertise `supportsTools = false`
    /// (for models whose chat template doesn't understand tools) the
    /// tool list is dropped silently and the run proceeds text-only.
    public struct MLXProvider: LLMProvider {
        // MARK: Lifecycle

        public init(
            capabilities: MLXModelCapabilities,
            store: MLXModelStore,
            defaultInstructions: String? = nil,
            generationParameters: GenerateParameters = GenerateParameters()
        ) {
            self.modelCapabilities = capabilities
            self.store = store
            self.defaultInstructions = defaultInstructions
            self.generationParameters = generationParameters
            self.capabilities = ProviderCapabilities(
                modelIdentifier: capabilities.id,
                supportsStreaming: true,
                supportsToolUse: capabilities.supportsTools,
                supportsParallelToolCalls: false,
                supportsVision: capabilities.supportsVision,
                supportsAudio: false,
                supportsStructuredOutput: false,
                supportsSystemPrompt: true,
                maxContextTokens: capabilities.contextWindow
            )
        }

        // MARK: Public

        public let capabilities: ProviderCapabilities

        public func stream(
            messages: [Aria.Message],
            tools: [ToolDefinition],
            options _: Aria.GenerationOptions
        ) -> AsyncThrowingStream<ProviderEvent, any Error> {
            // This is the dynamically-dispatched protocol method, so
            // it MUST consume `tools`. The `executableTools` overload
            // below lives on a protocol extension and would never
            // reach us via `any LLMProvider` dispatch — its
            // `executableTools` would silently be lost. Forwarding
            // through here means the agent always sees its tools.
            self.streamCore(messages: messages, toolDefinitions: tools)
        }

        public func stream(
            messages: [Aria.Message],
            executableTools: [AnyTool],
            options: Aria.GenerationOptions
        ) -> AsyncThrowingStream<ProviderEvent, any Error> {
            // Direct callers (i.e. consumers using `MLXProvider`
            // concretely rather than through `any LLMProvider`) reach
            // this overload via static dispatch. Funnel through the
            // same path as the protocol method.
            self.stream(
                messages: messages,
                tools: executableTools.map(\.definition),
                options: options
            )
        }

        // MARK: Private

        private static let logger = Logger(
            subsystem: "com.aria.mlx",
            category: "provider"
        )

        private let modelCapabilities: MLXModelCapabilities
        private let store: MLXModelStore
        private let defaultInstructions: String?
        private let generationParameters: GenerateParameters

        /// Default path used for every non-Gemma-4 model: hand
        /// `mlx-swift-lm` `Chat.Message`s and let its
        /// `MessageGenerator` translate.
        private static func chatUserInput(
            from messages: [Aria.Message],
            defaultInstructions: String?,
            toolDefinitions: [ToolDefinition]
        ) throws -> UserInput {
            var chat: [Chat.Message] = []
            var instructionsParts: [String] = []
            if let defaultInstructions, !defaultInstructions.isEmpty {
                instructionsParts.append(defaultInstructions)
            }
            for message in messages {
                switch message.role {
                case .system:
                    if !message.textContent.isEmpty {
                        instructionsParts.append(message.textContent)
                    }
                case .user:
                    chat.append(.user(
                        message.textContent,
                        images: Self.images(in: message)
                    ))
                case .assistant:
                    chat.append(.assistant(message.textContent))
                case .tool:
                    chat.append(.tool(message.textContent))
                }
            }
            if !instructionsParts.isEmpty {
                chat.insert(
                    .system(instructionsParts.joined(separator: "\n\n")),
                    at: 0
                )
            }
            // Use the chat-specific init: it walks the messages and
            // populates `UserInput.images`. The `init(prompt:...)`
            // overload leaves `images` empty on the `.chat` branch
            // (its `prompt.didSet` doesn't run inside init — the
            // library author's own comment), so VLM processors like
            // Gemma 4 see `input.images.isEmpty == true` and skip
            // image-token expansion, leaving the model effectively
            // blind to the attached image.
            return UserInput(
                chat: chat,
                tools: MLXToolBridge.toolSpecs(fromDefinitions: toolDefinitions)
            )
        }

        /// Gemma 4-specific path: emit OpenAI Chat Completions
        /// shape so the model's chat template renders prior tool
        /// calls and their responses. Bypasses `Chat.Message` (which
        /// has no `tool_calls` field) and the
        /// `Gemma4MessageGenerator` (which would drop them).
        private static func gemma4UserInput(
            from messages: [Aria.Message],
            defaultInstructions: String?,
            toolDefinitions: [ToolDefinition]
        ) -> UserInput {
            var raw: [MLXLMCommon.Message] = []
            var instructionsParts: [String] = []
            if let defaultInstructions, !defaultInstructions.isEmpty {
                instructionsParts.append(defaultInstructions)
            }
            for message in messages where message.role == .system {
                if !message.textContent.isEmpty {
                    instructionsParts.append(message.textContent)
                }
            }
            if !instructionsParts.isEmpty {
                raw.append([
                    "role": "system",
                    "content": instructionsParts.joined(separator: "\n\n")
                ])
            }

            var allImages: [UserInput.Image] = []
            for message in messages where message.role != .system {
                allImages.append(contentsOf: Self.images(in: message))
                raw.append(Self.gemma4Message(from: message))
            }

            return UserInput(
                prompt: .messages(raw),
                images: allImages,
                tools: MLXToolBridge.toolSpecs(fromDefinitions: toolDefinitions)
            )
        }

        /// Convert one `Aria.Message` into the dict shape
        /// Gemma 4's chat template understands. User content gets
        /// the typed-parts array (so `[{type:"image"}]` triggers
        /// image-token expansion); assistant tool calls land in a
        /// `tool_calls` array; tool messages carry `tool_call_id`.
        private static func gemma4Message(
            from message: Aria.Message
        ) -> MLXLMCommon.Message {
            switch message.role {
            case .user:
                return self.gemma4UserMessage(from: message)
            case .assistant:
                return self.gemma4AssistantMessage(from: message)
            case .tool:
                var dict: MLXLMCommon.Message = [
                    "role": "tool",
                    "content": message.textContent
                ]
                if let callId = message.toolCallId {
                    dict["tool_call_id"] = callId
                }
                return dict
            case .system:
                // Caller filters system messages into instructionsParts.
                return ["role": "system", "content": message.textContent]
            }
        }

        private static func gemma4UserMessage(
            from message: Aria.Message
        ) -> MLXLMCommon.Message {
            var contentParts: [[String: any Sendable]] = []
            for part in message.content where part.isImage {
                contentParts.append(["type": "image"])
            }
            contentParts.append(["type": "text", "text": message.textContent])
            return ["role": "user", "content": contentParts]
        }

        private static func gemma4AssistantMessage(
            from message: Aria.Message
        ) -> MLXLMCommon.Message {
            var dict: MLXLMCommon.Message = [
                "role": "assistant",
                "content": message.textContent
            ]
            if !message.toolCalls.isEmpty {
                dict["tool_calls"] = message.toolCalls.map { call in
                    [
                        "id": call.id,
                        "type": "function",
                        "function": [
                            "name": call.name,
                            "arguments": Self.argumentsForChatTemplate(call.arguments)
                        ] as [String: any Sendable]
                    ] as [String: any Sendable]
                }
            }
            return dict
        }

        /// Render `JSONValue` into the loosely-typed `Any` shape the
        /// chat template's `format_argument` macro can iterate. The
        /// template inspects whether a value is a string vs. mapping
        /// vs. sequence, so we hand it plain Foundation types.
        private static func argumentsForChatTemplate(
            _ value: Aria.JSONValue
        ) -> any Sendable {
            switch value {
            case .null: NSNull()
            case let .bool(bool): bool
            case let .integer(int): int
            case let .number(double): double
            case let .string(string): string
            case let .array(values):
                values.map(Self.argumentsForChatTemplate(_:))
            case let .object(values):
                values.mapValues(Self.argumentsForChatTemplate(_:))
            }
        }

        /// Pull every `ContentPart.image` off a `Message` and convert
        /// to `MLXLMCommon.UserInput.Image`. Aria's data and url
        /// sources map directly; identifier sources fall through to
        /// the consumer (we'd need a platform-specific resolver to
        /// expand them). `CIImage(data:)` decodes JPEG / HEIC / PNG
        /// natively, so we hand that straight to MLX without a
        /// CGImage round-trip — the prior round-trip was creating a
        /// fresh `CIContext` per image and silently dropping any
        /// `createCGImage` failure under memory pressure.
        private static func images(in message: Aria.Message) -> [UserInput.Image] {
            var result: [UserInput.Image] = []
            for part in message.content {
                guard case let .image(image) = part else {
                    continue
                }
                switch image.source {
                case let .data(data, mimeType):
                    if let ciImage = CIImage(data: data) {
                        result.append(.ciImage(ciImage))
                    } else {
                        Self.logger.error(
                            "Failed to decode image data: \(data.count) bytes, mime=\(mimeType)"
                        )
                    }
                case let .url(url):
                    result.append(.url(url))
                case .identifier:
                    // Identifier resolution requires platform context
                    // (e.g. PHAsset on Apple). Skipped here so the
                    // provider doesn't pull in PhotosUI; consumers
                    // resolve to data() before passing the message.
                    continue
                }
            }
            return result
        }

        /// Forward `Gemma4ToolCallStreamParser.Event`s into the
        /// provider's continuation, mirroring the dispatch the main
        /// generation loop performs for `Generation` events.
        private static func dispatch(
            parserEvents: [Gemma4ToolCallStreamParser.Event],
            continuation: AsyncThrowingStream<ProviderEvent, any Error>.Continuation,
            pendingToolCalls: inout [Aria.ToolCall]
        ) {
            for event in parserEvents {
                switch event {
                case let .textDelta(text):
                    if !text.isEmpty {
                        continuation.yield(.textDelta(text))
                    }
                case let .toolCall(call):
                    pendingToolCalls.append(call)
                    continuation.yield(.toolCallStart(call))
                    continuation.yield(.toolCallEnd(id: call.id))
                }
            }
        }

        /// Convert Aria's `[Message]` history into `MLXLMCommon.UserInput`.
        /// System messages collapse into a single instructions message
        /// (combined with `defaultInstructions`); user/assistant/tool
        /// messages map one-for-one to `Chat.Message`. When `Aria`
        /// `ContentPart.image` parts are present on a user message,
        /// they're converted to `MLXLMCommon.UserInput.Image` and
        /// attached to that message's `images:`. Vision-only parts
        /// the model doesn't understand are silently dropped — the
        /// chat agent and provider stay decoupled.
        private func userInput(
            from messages: [Aria.Message],
            defaultInstructions: String?,
            toolDefinitions: [ToolDefinition]
        ) throws -> UserInput {
            // Gemma 4's chat template only renders tool responses
            // when the preceding assistant message carries a
            // `tool_calls` array and the tool message carries
            // `tool_call_id` (OpenAI Chat Completions shape).
            // `Gemma4MessageGenerator` produces plain
            // `{role, content}` dicts and drops orphaned `role:tool`
            // messages, so we lose every tool round-trip — which
            // makes the model loop on the same tool call. Build raw
            // `[MLXLMCommon.Message]` dicts directly for that family.
            if self.modelCapabilities.usesGemma4ToolFormat {
                return Self.gemma4UserInput(
                    from: messages,
                    defaultInstructions: defaultInstructions,
                    toolDefinitions: toolDefinitions
                )
            }
            return try Self.chatUserInput(
                from: messages,
                defaultInstructions: defaultInstructions,
                toolDefinitions: toolDefinitions
            )
        }

        private func streamCore(
            messages: [Aria.Message],
            toolDefinitions: [ToolDefinition]
        ) -> AsyncThrowingStream<ProviderEvent, any Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    await self.runHandlingErrors(
                        messages: messages,
                        toolDefinitions: toolDefinitions,
                        continuation: continuation
                    )
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        private func runHandlingErrors(
            messages: [Aria.Message],
            toolDefinitions: [ToolDefinition],
            continuation: AsyncThrowingStream<ProviderEvent, any Error>.Continuation
        ) async {
            do {
                try await self.run(
                    messages: messages,
                    toolDefinitions: toolDefinitions,
                    continuation: continuation
                )
            } catch is CancellationError {
                continuation.finish(throwing: AgentError.cancelled)
            } catch let error as AgentError {
                continuation.finish(throwing: error)
            } catch {
                continuation.finish(
                    throwing: AgentError.providerFailed(
                        "MLXProvider stream failed",
                        underlying: ErrorBox(error)
                    )
                )
            }
        }

        private func run(
            messages: [Aria.Message],
            toolDefinitions: [ToolDefinition],
            continuation: AsyncThrowingStream<ProviderEvent, any Error>.Continuation
        ) async throws {
            let container = try await self.store.container(
                for: self.modelCapabilities.id,
                kind: self.modelCapabilities.kind,
                toolCallFormat: self.modelCapabilities.toolCallFormat
            )
            let toolsForModel = self.modelCapabilities.supportsTools ? toolDefinitions : []
            let userInput = try self.userInput(
                from: messages,
                defaultInstructions: self.defaultInstructions,
                toolDefinitions: toolsForModel
            )
            let lmInput = try await container.prepare(input: userInput)
            let generation = try await container.generate(
                input: lmInput,
                parameters: self.generationParameters
            )
            try await self.consume(
                generation: generation,
                continuation: continuation
            )
        }

        /// Pump events from `mlx-swift-lm`'s `Generation` stream into
        /// the provider's continuation. Gemma 4's tool-call format
        /// isn't recognised by any built-in parser, so for that
        /// family we tee `.chunk` text through
        /// `Gemma4ToolCallStreamParser` to recover tool calls.
        private func consume(
            generation: AsyncStream<Generation>,
            continuation: AsyncThrowingStream<ProviderEvent, any Error>.Continuation
        ) async throws {
            let messageId = UUID().uuidString
            continuation.yield(.messageStart(messageId: messageId))

            var pendingToolCalls: [Aria.ToolCall] = []
            var gemma4Parser: Gemma4ToolCallStreamParser? =
                self.modelCapabilities.usesGemma4ToolFormat
                    ? Gemma4ToolCallStreamParser()
                    : nil

            for await event in generation {
                try Task.checkCancellation()
                self.handle(
                    event: event,
                    gemma4Parser: &gemma4Parser,
                    pendingToolCalls: &pendingToolCalls,
                    continuation: continuation
                )
            }

            if var parser = gemma4Parser {
                Self.dispatch(
                    parserEvents: parser.flush(),
                    continuation: continuation,
                    pendingToolCalls: &pendingToolCalls
                )
            }

            let finishReason: FinishReason = pendingToolCalls.isEmpty ? .endTurn : .toolUse
            continuation.yield(.messageStop(finishReason))
            continuation.finish()
        }

        private func handle(
            event: Generation,
            gemma4Parser: inout Gemma4ToolCallStreamParser?,
            pendingToolCalls: inout [Aria.ToolCall],
            continuation: AsyncThrowingStream<ProviderEvent, any Error>.Continuation
        ) {
            switch event {
            case let .chunk(text):
                if var parser = gemma4Parser {
                    let parserEvents = parser.process(text)
                    gemma4Parser = parser
                    Self.dispatch(
                        parserEvents: parserEvents,
                        continuation: continuation,
                        pendingToolCalls: &pendingToolCalls
                    )
                } else {
                    continuation.yield(.textDelta(text))
                }
            case let .toolCall(mlxCall):
                let ariaCall = MLXToolBridge.ariaToolCall(from: mlxCall)
                pendingToolCalls.append(ariaCall)
                continuation.yield(.toolCallStart(ariaCall))
                continuation.yield(.toolCallEnd(id: ariaCall.id))
            case let .info(info):
                continuation.yield(.usage(TokenUsage(
                    inputTokens: info.promptTokenCount,
                    outputTokens: info.generationTokenCount
                )))
            }
        }
    }

    // swiftlint:enable type_body_length

    extension Aria.ContentPart {
        fileprivate var isImage: Bool {
            if case .image = self {
                true
            } else {
                false
            }
        }
    }
#endif
