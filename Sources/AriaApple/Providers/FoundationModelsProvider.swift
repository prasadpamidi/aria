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
    /// History is handed to the model as a `FoundationModels.Transcript`:
    /// system prompts become `Instructions`, prior user turns become
    /// `prompt` entries, prior assistant text becomes `response` entries,
    /// prior tool calls become `toolCalls` entries, and prior tool
    /// results become `toolOutput` entries. Only the *last* message in
    /// the input array is sent as the new prompt to `streamResponse(to:)`.
    /// This avoids the transcript-style hallucination the model produces
    /// when given concatenated `User: …\nAssistant: …` text.
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

        /// Pull the new-turn prompt out of the message list. Returns the
        /// text that should be sent via `streamResponse(to:)` plus the
        /// remaining history that becomes the `Transcript`.
        ///
        /// Throws when there is no usable message at the end. The agent
        /// loop always passes the latest user message last, so the `.user`
        /// branch is the production path; the trailing-`.tool`/.assistant
        /// branches keep the helper composable for direct provider use.
        static func extractPrompt(
            from messages: [Message]
        ) throws -> (prompt: String, history: [Message]) {
            guard let last = messages.last else {
                throw AgentError.configurationInvalid(
                    "FoundationModelsProvider needs at least one message"
                )
            }
            guard !last.textContent.isEmpty else {
                throw AgentError.configurationInvalid(
                    "Last message must carry text to seed the next response"
                )
            }
            return (last.textContent, Array(messages.dropLast()))
        }

        /// Convert prior `Message` history into a `Transcript`. System
        /// messages collapse into a single `Instructions` entry (along
        /// with the configured default instructions and the bridge tool
        /// definitions). Other roles map to their corresponding entry
        /// type one-for-one.
        static func buildTranscript(
            history: [Message],
            defaultInstructions: String?,
            toolDefinitions: [Transcript.ToolDefinition]
        ) -> Transcript {
            var entries: [Transcript.Entry] = []
            if let instructions = self.makeInstructions(
                history: history,
                defaultInstructions: defaultInstructions,
                toolDefinitions: toolDefinitions
            ) {
                entries.append(.instructions(instructions))
            }

            let toolNameByCallId = Self.toolNameMap(in: history)
            for message in history where message.role != .system {
                entries.append(contentsOf: self.entries(for: message, toolNames: toolNameByCallId))
            }
            return Transcript(entries: entries)
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

        // Transcript construction helpers live in
        // FoundationModelsTranscript.swift to keep this type body small.

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

            let (prompt, history) = try Self.extractPrompt(from: messages)
            let bridgeTools = try Self.buildBridgeTools(
                from: executableTools,
                continuation: continuation
            )
            // Tools are advertised exclusively through `LanguageModelSession.init(tools:)`.
            // Putting them in `Transcript.Instructions.toolDefinitions` as well caused the
            // model to mimic the "ToolName: arguments" prompt format in its text response
            // instead of invoking the tools through FoundationModels' native function-call
            // path — see PR #N for the diagnostic screenshots.
            let transcript = Self.buildTranscript(
                history: history,
                defaultInstructions: self.defaultInstructions,
                toolDefinitions: []
            )
            let session = LanguageModelSession(
                tools: bridgeTools,
                transcript: transcript
            )

            let messageId = UUID().uuidString
            continuation.yield(.messageStart(messageId: messageId))

            var emittedCount = 0
            let stream = session.streamResponse(to: prompt)
            for try await snapshot in stream {
                try Task.checkCancellation()
                // Extract the cumulative text synchronously inside the loop
                // body so the non-Sendable `Snapshot` never crosses an
                // await boundary.
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
