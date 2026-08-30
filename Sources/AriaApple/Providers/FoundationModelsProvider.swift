#if canImport(FoundationModels)
    import Aria
    import Foundation
    import FoundationModels
    import os

    private let fmLog = Logger(subsystem: "com.aria.apple", category: "foundationmodels")

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
            capabilities: ProviderCapabilities = .foundationModelsDefault,
            typedTools: [FoundationModelsToolFactory] = []
        ) {
            self.init(
                defaultInstructions: defaultInstructions,
                capabilities: capabilities,
                typedTools: typedTools,
                sessionFactory: .systemDefault
            )
        }

        init(
            defaultInstructions: String? = nil,
            capabilities: ProviderCapabilities = .foundationModelsDefault,
            typedTools: [FoundationModelsToolFactory] = [],
            sessionFactory: FoundationModelsSessionFactory
        ) {
            self.defaultInstructions = defaultInstructions
            self.capabilities = capabilities
            self.typedTools = typedTools
            self.sessionFactory = sessionFactory
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
            // when tools should be executed. This path has no selection
            // to honour, so every registered tool is offered.
            self.streamCore(
                messages: messages,
                executableTools: [],
                honourSelection: false
            )
        }

        public func stream(
            messages: [Message],
            executableTools: [AnyTool],
            options _: Aria.GenerationOptions
        ) -> AsyncThrowingStream<ProviderEvent, any Error> {
            // A selection arrived, so an empty one means *none* — not
            // "no preference". Conflating the two let a deliberate
            // "send no tools" decision reach the model as "send all
            // twelve": `DefaultContextAssembler(unrankedFillLimit: 0)`
            // selected nothing for a statement needing no tool, and the
            // request went out at 4,091 tokens against a 4,096 ceiling
            // and was refused. Two features written a week apart, each
            // correct alone.
            self.streamCore(
                messages: messages,
                executableTools: executableTools,
                honourSelection: true
            )
        }

        // MARK: Internal

        static let maximumToolNameLength = 64

        // Read by extensions in sibling files (e.g.
        // `FoundationModelsStructured.swift`).
        let defaultInstructions: String?
        let typedTools: [FoundationModelsToolFactory]
        let sessionFactory: FoundationModelsSessionFactory

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

        /// Partition tools into those FoundationModels will accept and
        /// human-readable reasons for the rest.
        ///
        /// Deliberately conservative about names: identifiers that are
        /// ASCII letters, digits and underscores are what every
        /// provider agrees on, and a runtime-named tool has no author
        /// to catch a bad one at compile time.
        static func registrable(
            _ tools: [any FoundationModels.Tool]
        ) -> (accepted: [any FoundationModels.Tool], rejected: [String]) {
            var accepted: [any FoundationModels.Tool] = []
            var rejected: [String] = []
            var seen: Set<String> = []
            for tool in tools {
                let name = tool.name
                if name.isEmpty {
                    rejected.append("(empty name)")
                    continue
                }
                if name.count > Self.maximumToolNameLength {
                    rejected.append("\(name.prefix(40))… — name is \(name.count) characters")
                    continue
                }
                let valid = name.allSatisfy { character in
                    character.isASCII && (character.isLetter || character.isNumber || character == "_")
                }
                if !valid {
                    rejected.append("\(name) — name has characters outside [A-Za-z0-9_]")
                    continue
                }
                if !seen.insert(name).inserted {
                    rejected.append("\(name) — duplicate name")
                    continue
                }
                accepted.append(tool)
            }
            return (accepted, rejected)
        }

        static func checkAvailability() throws {
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

        // MARK: Private

        // Transcript construction helpers live in
        // FoundationModelsTranscript.swift to keep this type body small.

        private func streamCore(
            messages: [Message],
            executableTools: [AnyTool],
            honourSelection: Bool
        ) -> AsyncThrowingStream<ProviderEvent, any Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    await self.runHandlingErrors(
                        messages: messages,
                        executableTools: executableTools,
                        honourSelection: honourSelection,
                        continuation: continuation
                    )
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        private func runHandlingErrors(
            messages: [Message],
            executableTools: [AnyTool],
            honourSelection: Bool,
            continuation: AsyncThrowingStream<ProviderEvent, any Error>.Continuation
        ) async {
            do {
                try await self.run(
                    messages: messages,
                    executableTools: executableTools,
                    honourSelection: honourSelection,
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
            honourSelection: Bool,
            continuation: AsyncThrowingStream<ProviderEvent, any Error>.Continuation
        ) async throws {
            let (prompt, history) = try Self.extractPrompt(from: messages)
            // Build the typed FM tools. Each factory is invoked with a
            // closure that yields events into this stream's
            // continuation, so per-call `toolCallExecuted` events flow
            // back through the agent layer. FM's iOS 26 tool router
            // only resolves compile-time `@Generable` arguments, so the
            // tools themselves must come from `typedTools` — but which
            // of them to offer is the caller's decision.
            //
            // `executableTools` used to be ignored entirely, so every
            // tool registered at construction reached the session on
            // every turn no matter what the caller selected. With a
            // large tool surface that silently overflows the model's
            // 4,096-token window: an agent that had narrowed 27 tools
            // to 8 still sent all 27, and the request was refused at
            // 6,042 tokens.
            let allTools: [any FoundationModels.Tool] = self.typedTools.map { factory in
                factory { event in continuation.yield(event) }
            }
            // An empty selection means the caller expressed no
            // preference — the definition-only entry point supplies
            // none — so offer everything rather than nothing.
            let fmTools: [any FoundationModels.Tool]
            if executableTools.isEmpty {
                fmTools = honourSelection ? [] : allTools
            } else {
                let selected = Set(executableTools.map(\.name))
                fmTools = allTools.filter { selected.contains($0.name) }
            }
            // Drop tools FoundationModels cannot register, rather than
            // letting one of them take the turn down.
            //
            // `LanguageModelSession(tools:)` fails as a whole if any
            // tool is malformed — duplicate names above all — and the
            // failure surfaces as an opaque `tokengeneration Code=10`
            // during prefill, with no tokens, no tool calls, and
            // nothing naming the offender. Runtime-named tools make
            // that reachable: workflow tools derive their name by
            // snake-casing a user-entered title, so two workflows
            // called "Morning Brief" and "morning brief!" collide, and
            // a title with an accent produces a non-ASCII identifier.
            //
            // A dropped tool costs one capability for one turn. An
            // unregistrable session costs the turn, and gives nobody a
            // way to find out why.
            let (registrableTools, rejected) = Self.registrable(fmTools)
            for reason in rejected {
                fmLog.error("tool not offered to FoundationModels: \(reason, privacy: .public)")
            }
            let toolDefinitions = registrableTools.map { Transcript.ToolDefinition(tool: $0) }
            let transcript = Self.buildTranscript(
                history: history,
                defaultInstructions: self.defaultInstructions,
                toolDefinitions: toolDefinitions
            )
            var requirements: FoundationModelsSessionRequirements = []
            if !registrableTools.isEmpty {
                requirements.insert(.toolCalling)
            }
            let session = try self.sessionFactory.makeSession(
                tools: registrableTools,
                transcript: transcript,
                requirements: requirements
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
        /// typed-bridge adapter; the provider emits
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
            // The on-device model enforces a hard 4,096-token ceiling
            // across prompt *and* completion, and rejects the request
            // with `exceededContextWindowSize` rather than truncating.
            //
            // Reporting `nil` left callers nothing to budget against,
            // so they fell back to an optimistic default. That
            // produced exactly this failure in the field: a request
            // assembled against an assumed 8,192 and refused at 4,090
            // of 4,096.
            maxContextTokens: 4096,
            usableContextTokens: 4096
        )
    }

#endif
