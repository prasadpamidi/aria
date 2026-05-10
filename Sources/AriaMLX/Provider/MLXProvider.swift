#if canImport(MLXLMCommon)
    import Aria
    import Foundation
    import MLXLMCommon

    // MARK: - MLXProvider

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
            tools _: [ToolDefinition],
            options _: Aria.GenerationOptions
        ) -> AsyncThrowingStream<ProviderEvent, any Error> {
            // No `AnyTool`s available on this overload — the agent's
            // tool-calling overload is what carries them.
            self.streamCore(messages: messages, executableTools: [])
        }

        public func stream(
            messages: [Aria.Message],
            executableTools: [AnyTool],
            options _: Aria.GenerationOptions
        ) -> AsyncThrowingStream<ProviderEvent, any Error> {
            self.streamCore(messages: messages, executableTools: executableTools)
        }

        // MARK: Private

        private let modelCapabilities: MLXModelCapabilities
        private let store: MLXModelStore
        private let defaultInstructions: String?
        private let generationParameters: GenerateParameters

        /// Convert Aria's `[Message]` history into `MLXLMCommon.UserInput`.
        /// System messages collapse into a single instructions message
        /// (combined with `defaultInstructions`); user/assistant/tool
        /// messages map one-for-one to `Chat.Message`.
        private static func userInput(
            from messages: [Aria.Message],
            defaultInstructions: String?,
            tools: [AnyTool]
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
                    chat.append(.user(message.textContent))
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
            return UserInput(
                prompt: .chat(chat),
                tools: MLXToolBridge.toolSpecs(from: tools)
            )
        }

        private func streamCore(
            messages: [Aria.Message],
            executableTools: [AnyTool]
        ) -> AsyncThrowingStream<ProviderEvent, any Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    await self.runHandlingErrors(
                        messages: messages,
                        executableTools: executableTools,
                        continuation: continuation
                    )
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        private func runHandlingErrors(
            messages: [Aria.Message],
            executableTools: [AnyTool],
            continuation: AsyncThrowingStream<ProviderEvent, any Error>.Continuation
        ) async {
            do {
                try await self.run(
                    messages: messages,
                    executableTools: executableTools,
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
            executableTools: [AnyTool],
            continuation: AsyncThrowingStream<ProviderEvent, any Error>.Continuation
        ) async throws {
            let container = try await self.store.container(for: self.modelCapabilities.id)
            let userInput = try Self.userInput(
                from: messages,
                defaultInstructions: self.defaultInstructions,
                tools: self.modelCapabilities.supportsTools ? executableTools : []
            )
            let lmInput = try await container.prepare(input: userInput)
            let generation = try await container.generate(
                input: lmInput,
                parameters: self.generationParameters
            )

            let messageId = UUID().uuidString
            continuation.yield(.messageStart(messageId: messageId))

            var pendingToolCalls: [Aria.ToolCall] = []
            for await event in generation {
                try Task.checkCancellation()
                switch event {
                case let .chunk(text):
                    continuation.yield(.textDelta(text))
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

            let finishReason: FinishReason = pendingToolCalls.isEmpty ? .endTurn : .toolUse
            continuation.yield(.messageStop(finishReason))
            continuation.finish()
        }
    }
#endif
