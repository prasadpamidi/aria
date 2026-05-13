#if canImport(FoundationModels)
    import Aria
    import Foundation
    import FoundationModels
    import Tracing

    // MARK: - Agent + structured response

    @available(iOS 26.0, macOS 26.0, *)
    extension Agent {
        /// Stream a structured response of type `Content`. Yields partial
        /// parses as the model generates (on `FoundationModelsProvider`
        /// only), any tool calls the provider resolves during
        /// generation, and concludes with `.finish(Content)`.
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
        /// Provider-agnostic. Two paths internally:
        /// - `FoundationModelsProvider`: native guided generation via
        ///   `streamStructured(_:as:)`. Emits `.partial(snapshot)`s as
        ///   the model decodes the schema incrementally.
        /// - Any other `LLMProvider`: accumulates the provider's
        ///   `.textDelta` chunks, then decodes the final assistant text
        ///   as JSON via `GeneratedContent(json:)` + `Content.init(_:)`.
        ///   No `.partial` snapshots are emitted on this path — the
        ///   provider's text isn't a partial parse of the schema — so
        ///   consumers that render partials will only see `.finish` from
        ///   a non-FM provider.
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
            let finalContent: Content? =
                if let fmProvider = self.config.provider as? FoundationModelsProvider {
                    try await Self.consumeFoundationModelsStructured(
                        provider: fmProvider,
                        messages: providerMessages,
                        type: type,
                        state: &state,
                        continuation: continuation
                    )
                } else {
                    try await self.consumeGenericStructured(
                        messages: providerMessages,
                        type: type,
                        state: &state,
                        continuation: continuation
                    )
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

        /// Consume FoundationModels' native guided-generation stream —
        /// the fast path, with mid-flight `.partial` snapshots.
        private static func consumeFoundationModelsStructured<Content: Generable & Sendable>(
            provider: FoundationModelsProvider,
            messages: [Message],
            type: Content.Type,
            state: inout AgentState,
            continuation: AsyncThrowingStream<StructuredResponseEvent<Content>, any Error>.Continuation
        ) async throws -> Content? where Content.PartiallyGenerated: Sendable {
            var finalContent: Content?
            for try await event in provider.streamStructured(messages: messages, as: type) {
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
            return finalContent
        }

        /// Consume any `LLMProvider`'s `.textDelta` stream and JSON-decode
        /// the accumulated text into `Content` via `GeneratedContent`.
        ///
        /// Forwards `.toolCallExecuted` events through to the structured
        /// stream so providers that resolve tools server-side (e.g.
        /// `NioraServerProvider`) surface the same UX shape as the FM
        /// fast path. Other `ProviderEvent`s are framing-only and don't
        /// have a `StructuredResponseEvent` equivalent — silently
        /// dropped. No `.partial` snapshots fire on this path.
        private func consumeGenericStructured<Content: Generable & Sendable>(
            messages: [Message],
            type: Content.Type,
            state: inout AgentState,
            continuation: AsyncThrowingStream<StructuredResponseEvent<Content>, any Error>.Continuation
        ) async throws -> Content? where Content.PartiallyGenerated: Sendable {
            let stream = self.config.provider.stream(
                messages: messages,
                tools: [],
                options: self.config.generationOptions
            )
            var accumulated = ""
            for try await event in stream {
                try Task.checkCancellation()
                switch event {
                case let .textDelta(chunk):
                    accumulated += chunk
                case let .toolCallExecuted(call, result):
                    Self.recordToolCall(call: call, result: result, in: &state)
                    continuation.yield(.toolCallExecuted(call: call, result: result))
                case .messageStart, .toolCallStart, .toolCallDelta, .toolCallEnd, .usage, .messageStop:
                    // Framing / token-usage events have no
                    // `StructuredResponseEvent` analogue; the final-text
                    // decode below is what carries the contract.
                    continue
                }
            }

            let trimmed = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw AgentError.providerFailed(
                    "Provider yielded no text for Agent.respond(_:as: \(type)) — " +
                        "structured-output decode needs at least one .textDelta.",
                    underlying: nil
                )
            }
            do {
                let generated = try GeneratedContent(json: trimmed)
                let value = try Content(generated)
                continuation.yield(.finish(value))
                return value
            } catch {
                throw AgentError.providerFailed(
                    "Failed to decode \(type) from provider text: \(error)",
                    underlying: ErrorBox(error)
                )
            }
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
