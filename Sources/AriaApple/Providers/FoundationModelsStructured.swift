#if canImport(FoundationModels)
    import Aria
    import Foundation
    import FoundationModels

    // MARK: - FoundationModelsProvider + structured response

    @available(iOS 26.0, macOS 26.0, *)
    extension FoundationModelsProvider {
        /// Stream a structured response of type `Content` from the
        /// session. Yields `.partial` snapshots as the model generates,
        /// `.toolCallExecuted` for tools FoundationModels resolves
        /// during generation, and concludes with `.finish(Content)`.
        ///
        /// The history portion of `messages` becomes the session
        /// `Transcript`; the *last* element's text seeds the new
        /// response (same convention as the text-streaming path).
        public func streamStructured<Content: Generable & Sendable>(
            messages: [Message],
            as type: Content.Type
        ) -> AsyncThrowingStream<StructuredResponseEvent<Content>, any Error>
        where Content.PartiallyGenerated: Sendable {
            AsyncThrowingStream { continuation in
                let task = Task {
                    await self.runStructuredHandlingErrors(
                        messages: messages,
                        type: type,
                        continuation: continuation
                    )
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        // MARK: Private

        private func runStructuredHandlingErrors<Content: Generable & Sendable>(
            messages: [Message],
            type: Content.Type,
            continuation: AsyncThrowingStream<
                StructuredResponseEvent<Content>, any Error
            >.Continuation
        ) async where Content.PartiallyGenerated: Sendable {
            do {
                try await self.runStructured(
                    messages: messages,
                    type: type,
                    continuation: continuation
                )
            } catch {
                continuation.finish(throwing: FoundationModelsErrorMapper.map(error))
            }
        }

        private func runStructured<Content: Generable & Sendable>(
            messages: [Message],
            type: Content.Type,
            continuation: AsyncThrowingStream<
                StructuredResponseEvent<Content>, any Error
            >.Continuation
        ) async throws where Content.PartiallyGenerated: Sendable {
            let (prompt, history) = try Self.extractPrompt(from: messages)

            // Forward each tool's `toolCallExecuted` ProviderEvent into
            // the structured stream so consumers see mid-response tool
            // activity. Other ProviderEvent cases would be
            // text-deltas/finish and don't apply during structured
            // generation, so we drop them.
            let fmTools: [any FoundationModels.Tool] = self.typedTools.map { factory in
                factory { event in
                    if case let .toolCallExecuted(call, result) = event {
                        continuation.yield(.toolCallExecuted(call: call, result: result))
                    }
                }
            }
            let toolDefinitions = fmTools.map { Transcript.ToolDefinition(tool: $0) }
            let transcript = Self.buildTranscript(
                history: history,
                defaultInstructions: self.defaultInstructions,
                toolDefinitions: toolDefinitions
            )
            var requirements: FoundationModelsSessionRequirements = [.guidedGeneration]
            if !fmTools.isEmpty {
                requirements.insert(.toolCalling)
            }
            let session = try self.sessionFactory.makeSession(
                tools: fmTools,
                transcript: transcript,
                requirements: requirements
            )

            let stream = session.streamResponse(to: prompt, generating: type)
            var lastRaw: GeneratedContent?
            for try await snapshot in stream {
                try Task.checkCancellation()
                continuation.yield(.partial(snapshot.content))
                lastRaw = snapshot.rawContent
            }

            guard let lastRaw else {
                throw AgentError.providerFailed(
                    "FoundationModels structured stream produced no snapshots",
                    underlying: nil
                )
            }
            let final = try Content(lastRaw)
            continuation.yield(.finish(final))
            continuation.finish()
        }
    }

#endif
