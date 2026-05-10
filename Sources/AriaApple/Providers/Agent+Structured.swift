#if canImport(FoundationModels)
    import Aria
    import Foundation
    import FoundationModels
    import Tracing

    // MARK: - Agent + structured response

    @available(iOS 26.0, macOS 26.0, *)
    extension Agent {
        /// Stream a structured response of type `Content` using the
        /// agent's configured `FoundationModelsProvider`. Yields partial
        /// parses as the model generates, any tool calls FM resolves
        /// during generation, and concludes with `.finish(Content)`.
        ///
        /// Applies the agent's middleware lifecycle around the structured
        /// turn:
        /// - `beforeRun` runs once with the input messages
        /// - `beforeStep` runs once before the provider stream begins
        ///   (this is where `RAGMiddleware` injects recalled context)
        /// - `afterStep` runs once after the stream completes, with the
        ///   final structured response appended as a JSON-encoded
        ///   assistant message (this is where `HistoryMiddleware`
        ///   persists the turn)
        /// - `afterRun` runs once at the end with `.finish(.endTurn)`
        ///
        /// Throws `AgentError.configurationInvalid` (delivered through
        /// the stream) if the agent is not backed by a
        /// `FoundationModelsProvider`.
        public func respond<Content: Generable & Sendable>(
            _ input: AgentInput,
            as type: Content.Type
        ) -> AsyncThrowingStream<StructuredResponseEvent<Content>, any Error>
        where Content.PartiallyGenerated: Sendable {
            AsyncThrowingStream { continuation in
                let task = Task {
                    await withSpan(AriaSemConv.Span.agentRespond, ofKind: .internal) { span in
                        span.attributes[AriaSemConv.GenAI.system] =
                            self.config.provider.capabilities.modelIdentifier
                        span.attributes[AriaSemConv.GenAI.requestModel] =
                            self.config.provider.capabilities.modelIdentifier
                        span.attributes[AriaSemConv.GenAI.operationName] = "structured_output"
                        if let threadId = self.config.threadId {
                            span.attributes[AriaSemConv.Aria.threadId] = threadId
                        }
                        await self.runStructuredHandlingErrors(
                            input: input,
                            type: type,
                            continuation: continuation
                        )
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        // MARK: Internal

        private func runStructuredHandlingErrors<Content: Generable & Sendable>(
            input: AgentInput,
            type: Content.Type,
            continuation: AsyncThrowingStream<StructuredResponseEvent<Content>, any Error>.Continuation
        ) async where Content.PartiallyGenerated: Sendable {
            do {
                try await self.runStructured(input: input, type: type, continuation: continuation)
            } catch is CancellationError {
                continuation.finish(throwing: AgentError.cancelled)
            } catch let error as AgentError {
                continuation.finish(throwing: error)
            } catch {
                continuation.finish(
                    throwing: AgentError.providerFailed(
                        "Agent.respond failed",
                        underlying: ErrorBox(error)
                    )
                )
            }
        }

        private func runStructured<Content: Generable & Sendable>(
            input: AgentInput,
            type: Content.Type,
            continuation: AsyncThrowingStream<StructuredResponseEvent<Content>, any Error>.Continuation
        ) async throws where Content.PartiallyGenerated: Sendable {
            guard let provider = self.config.provider as? FoundationModelsProvider else {
                throw AgentError.configurationInvalid(
                    "Agent.respond(_:as:) requires a FoundationModelsProvider"
                )
            }

            let threadId = self.config.threadId ?? UUID().uuidString
            var state = AgentState(threadId: threadId, messages: Self.messages(from: input))

            // Apply lifecycle prefix: beforeRun + beforeStep. Mirrors
            // the chat agent loop so RAGMiddleware / HistoryMiddleware
            // see the same shape they always do.
            state = try await self.applyMiddleware(state) { mw, current in
                try await mw.beforeRun(current)
            }
            state = try await self.applyMiddleware(state) { mw, current in
                try await mw.beforeStep(current)
            }

            let providerMessages = self.buildProviderMessages(state: state)
            var finalContent: Content?
            for try await event in provider.streamStructured(messages: providerMessages, as: type) {
                switch event {
                case .partial:
                    continuation.yield(event)
                case let .toolCallExecuted(call, result):
                    Self.recordToolCall(call: call, result: result, in: &state)
                    continuation.yield(event)
                case let .finish(content):
                    finalContent = content
                    continuation.yield(event)
                }
            }

            // Append the final structured response so HistoryMiddleware
            // captures it on `afterStep`. Encoded as JSON because
            // `Message.assistant` is text-only.
            if let final = finalContent {
                state.messages.append(.assistant(Self.encodeFinal(final)))
            }

            state = try await self.applyMiddleware(state) { mw, current in
                try await mw.afterStep(current)
            }
            let finalEvent = AgentEvent.finish(.endTurn)
            state = try await self.applyMiddleware(state) { mw, current in
                try await mw.afterRun(current, finalEvent: finalEvent)
            }
            continuation.finish()
        }

        // MARK: Helpers

        private func applyMiddleware(
            _ state: AgentState,
            block: (any AgentMiddleware, AgentState) async throws -> AgentState
        ) async throws -> AgentState {
            var current = state
            for middleware in self.config.middleware {
                current = try await block(middleware, current)
            }
            return current
        }

        private func buildProviderMessages(state: AgentState) -> [Message] {
            var result: [Message] = []
            if let systemPrompt = self.config.systemPrompt, !systemPrompt.isEmpty {
                result.append(.system(systemPrompt))
            }
            result.append(contentsOf: state.messages)
            return result
        }

        private static func messages(from input: AgentInput) -> [Message] {
            switch input {
            case let .message(value): [value]
            case let .messages(values): values
            }
        }

        /// Append an assistant tool-call + tool-result pair to the
        /// state so HistoryMiddleware persists the call on this turn.
        /// Mirrors what the chat agent loop's tool execution path
        /// records.
        private static func recordToolCall(
            call: ToolCall,
            result: ToolExecutionResult,
            in state: inout AgentState
        ) {
            state.messages.append(.assistant("", toolCalls: [call]))
            let payload = Self.renderJSONValue(result.output)
            state.messages.append(.tool(callId: call.id, text: payload))
        }

        private static func encodeFinal(_ value: some Generable) -> String {
            // Generable provides `generatedContent.jsonString`, the
            // canonical JSON shape FM uses internally. Avoids needing
            // an Encodable conformance the consumer's @Generable type
            // may not have.
            value.generatedContent.jsonString
        }

        private static func renderJSONValue(_ value: JSONValue) -> String {
            guard let data = try? value.canonicalData(),
                  let json = String(data: data, encoding: .utf8) else {
                return "{}"
            }
            return json
        }
    }

#endif
