#if canImport(FoundationModels)
    import Aria
    import Foundation
    import FoundationModels

    // MARK: - Agent + structured response

    @available(iOS 26.0, macOS 26.0, *)
    extension Agent {
        /// Stream a structured response of type `Content` using the
        /// agent's configured `FoundationModelsProvider`. Yields partial
        /// parses as the model generates, any tool calls FM resolves
        /// during generation, and concludes with `.finish(Content)`.
        ///
        /// V1 limitation: middleware (history persistence, RAG) is *not*
        /// applied for structured responses. Use `stream(_:)` for turns
        /// where middleware integration is required. Tools registered on
        /// the agent's provider via `typedTools` are visible to the
        /// session and may fire during generation.
        ///
        /// Throws `AgentError.configurationInvalid` (delivered through
        /// the stream) if the agent is not backed by a
        /// `FoundationModelsProvider`.
        public func respond<Content: Generable & Sendable>(
            _ input: AgentInput,
            as type: Content.Type
        ) -> AsyncThrowingStream<StructuredResponseEvent<Content>, any Error>
        where Content.PartiallyGenerated: Sendable {
            guard let provider = self.config.provider as? FoundationModelsProvider else {
                return AsyncThrowingStream { continuation in
                    continuation.finish(
                        throwing: AgentError.configurationInvalid(
                            "Agent.respond(_:as:) requires a FoundationModelsProvider"
                        )
                    )
                }
            }
            return provider.streamStructured(
                messages: Self.messages(from: input),
                as: type
            )
        }

        // MARK: Private

        private static func messages(from input: AgentInput) -> [Message] {
            switch input {
            case let .message(value): [value]
            case let .messages(values): values
            }
        }
    }

#endif
