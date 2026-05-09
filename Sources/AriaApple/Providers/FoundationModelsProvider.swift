#if canImport(FoundationModels)
    import Aria
    import Foundation
    import FoundationModels

    // MARK: - FoundationModelsProvider

    /// An `LLMProvider` backed by Apple's on-device `FoundationModels`.
    ///
    /// Requires iOS 26 / macOS 26 / iPadOS 26 / visionOS 26 at runtime. The
    /// surrounding module compiles on earlier OS versions but instances of
    /// this type cannot be constructed there — `@available` enforces that.
    ///
    /// PR 2 scope: text streaming only. Tool calling lands with the agent
    /// loop in PR 3, where the JSONSchema-based `Tool` protocol is bridged
    /// to FoundationModels' `Generable`-based tool surface.
    @available(iOS 26.0, macOS 26.0, *)
    public struct FoundationModelsProvider: LLMProvider {
        // MARK: Lifecycle

        public init(
            defaultInstructions: String? = nil,
            capabilities: ProviderCapabilities = .foundationModelsDefault
        ) {
            self.defaultInstructions = defaultInstructions
            self.capabilities = capabilities
        }

        // MARK: Public

        public let capabilities: ProviderCapabilities

        public func stream(
            messages: [Message],
            tools _: [ToolDefinition],
            options _: Aria.GenerationOptions
        ) -> AsyncThrowingStream<ProviderEvent, any Error> {
            // No `AnyTool`s available on this overload — the agent layer
            // calls `stream(messages:executableTools:options:)` instead
            // when tools should be executed. This path runs text-only.
            self.streamCore(messages: messages, executableTools: [])
        }

        public func stream(
            messages: [Message],
            executableTools: [AnyTool],
            options _: Aria.GenerationOptions
        ) -> AsyncThrowingStream<ProviderEvent, any Error> {
            self.streamCore(messages: messages, executableTools: executableTools)
        }

        // MARK: Internal

        /// Translate a message history into a system instruction and prompt
        /// payload suitable for `LanguageModelSession`. Exposed at internal
        /// access so it can be unit-tested without booting the model.
        static func translate(
            messages: [Message],
            defaultInstructions: String?
        ) -> (instructions: String, prompt: String) {
            var instructionParts: [String] = []
            if let defaultInstructions, !defaultInstructions.isEmpty {
                instructionParts.append(defaultInstructions)
            }

            var conversationParts: [String] = []

            for message in messages {
                let text = message.textContent
                guard !text.isEmpty else {
                    continue
                }
                switch message.role {
                case .system:
                    instructionParts.append(text)
                case .user:
                    conversationParts.append("User: \(text)")
                case .assistant:
                    conversationParts.append("Assistant: \(text)")
                case .tool:
                    let id = message.toolCallId ?? "unknown"
                    conversationParts.append("Tool[\(id)]: \(text)")
                }
            }

            let instructions = instructionParts.joined(separator: "\n\n")
            let prompt = conversationParts.isEmpty
                ? ""
                : conversationParts.joined(separator: "\n\n")
            return (instructions, prompt)
        }

        // MARK: Private

        private let defaultInstructions: String?

        private static func checkAvailability() throws {
            let availability = SystemLanguageModel.default.availability
            switch availability {
            case .available:
                return
            case let .unavailable(reason):
                throw AgentError.providerFailed(
                    "FoundationModels unavailable: \(String(describing: reason))",
                    underlying: nil
                )
            @unknown default:
                throw AgentError.providerFailed(
                    "FoundationModels availability unknown",
                    underlying: nil
                )
            }
        }

        private static func buildBridgeTools(
            from executableTools: [AnyTool],
            continuation: AsyncThrowingStream<ProviderEvent, any Error>.Continuation
        ) throws -> [any FoundationModels.Tool] {
            try executableTools.map { ariaTool in
                try AriaBridgeTool(ariaTool: ariaTool) { event in
                    continuation.yield(event)
                }
            }
        }

        private func streamCore(
            messages: [Message],
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
            messages: [Message],
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
                        "FoundationModels stream failed",
                        underlying: ErrorBox(error)
                    )
                )
            }
        }

        private func run(
            messages: [Message],
            executableTools: [AnyTool],
            continuation: AsyncThrowingStream<ProviderEvent, any Error>.Continuation
        ) async throws {
            try Self.checkAvailability()

            let (instructions, prompt) = Self.translate(
                messages: messages,
                defaultInstructions: self.defaultInstructions
            )

            guard !prompt.isEmpty else {
                throw AgentError.configurationInvalid(
                    "FoundationModelsProvider requires at least one user/assistant/tool message"
                )
            }

            let bridgeTools = try Self.buildBridgeTools(
                from: executableTools,
                continuation: continuation
            )
            let session = LanguageModelSession(
                tools: bridgeTools,
                instructions: instructions
            )

            let messageId = UUID().uuidString
            continuation.yield(.messageStart(messageId: messageId))

            var emittedCount = 0
            let stream = session.streamResponse(to: prompt)
            for try await snapshot in stream {
                try Task.checkCancellation()
                // `snapshot.content` is `String.PartiallyGenerated`, which for
                // primitive Generable types (`String`) is alias-equivalent to
                // `String`. Extract the value synchronously inside the loop
                // body so we never carry the non-Sendable `Snapshot` across
                // any concurrency boundary.
                let cumulative = String(describing: snapshot.content)
                guard cumulative.count > emittedCount else {
                    continue
                }
                let startIndex = cumulative.index(cumulative.startIndex, offsetBy: emittedCount)
                let delta = String(cumulative[startIndex...])
                continuation.yield(.textDelta(delta))
                emittedCount = cumulative.count
            }

            continuation.yield(.messageStop(.endTurn))
            continuation.finish()
        }
    }

    // MARK: - Capabilities

    @available(iOS 26.0, macOS 26.0, *)
    extension ProviderCapabilities {
        /// Default capabilities for `FoundationModelsProvider`.
        /// Tool support resolves inside the model session via the
        /// `AriaBridgeTool` adapter; the provider emits
        /// `ProviderEvent.toolCallExecuted` once each tool returns so the
        /// agent layer surfaces equivalent events to consumers.
        public static let foundationModelsDefault = ProviderCapabilities(
            modelIdentifier: "apple.foundationmodels.default",
            supportsStreaming: true,
            supportsToolUse: true,
            supportsParallelToolCalls: false,
            supportsVision: false,
            supportsAudio: false,
            supportsStructuredOutput: true,
            supportsSystemPrompt: true,
            maxContextTokens: nil
        )
    }

#endif
