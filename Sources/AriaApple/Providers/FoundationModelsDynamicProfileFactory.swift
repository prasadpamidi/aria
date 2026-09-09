#if canImport(FoundationModels)
    import Aria
    import FoundationModels

    public enum FoundationModelsTranscriptErrorPolicy: Sendable, Equatable {
        case revert
        case preserve
    }

    public enum FoundationModelsProfileLifecycleEvent: Sendable, Equatable {
        case activated
        case deactivated
        case prompt
        case response
        case reasoning
        case toolCall
        case toolOutput
    }

    @available(iOS 26.0, macOS 26.0, *)
    public struct FoundationModelsProfileConfiguration: Sendable {
        // MARK: Lifecycle

        public init(
            identifier: String,
            maximumResponseTokens: Int? = nil,
            historyLimit: Int? = nil,
            transcriptErrorHandling: FoundationModelsTranscriptErrorPolicy = .revert,
            lifecycleHandler: LifecycleHandler? = nil
        ) {
            self.identifier = identifier
            self.maximumResponseTokens = maximumResponseTokens
            self.historyLimit = historyLimit
            self.transcriptErrorHandling = transcriptErrorHandling
            self.lifecycleHandler = lifecycleHandler
        }

        // MARK: Public

        public typealias LifecycleHandler = @Sendable (
            FoundationModelsProfileLifecycleEvent,
            FoundationModelsProfileDescriptor
        ) async -> Void

        public let identifier: String
        public let maximumResponseTokens: Int?
        public let historyLimit: Int?
        public let transcriptErrorHandling: FoundationModelsTranscriptErrorPolicy
        public let lifecycleHandler: LifecycleHandler?
    }

    @available(iOS 26.0, macOS 26.0, *)
    public struct FoundationModelsProfileDescriptor: Equatable, Sendable {
        public let profileIdentifier: String
        public let modelIdentifier: String
        public let selectedToolNames: [String]
        public let instructions: String?
        public let maximumResponseTokens: Int?
        public let historyLimit: Int?
        public let transcriptErrorHandling: FoundationModelsTranscriptErrorPolicy
        public let hasLifecycleHandler: Bool
    }

    @available(iOS 26.0, macOS 26.0, *)
    enum FoundationModelsDynamicProfileFactory {
        // MARK: Internal

        static func validate(_ configuration: FoundationModelsProfileConfiguration) throws {
            guard !configuration.identifier.isEmpty else {
                throw AgentError.configurationInvalid(
                    "Foundation Models profile identifier must not be empty"
                )
            }
            if let maximumResponseTokens = configuration.maximumResponseTokens,
               maximumResponseTokens <= 0 {
                throw AgentError.configurationInvalid(
                    "Foundation Models maximum response tokens must be greater than zero"
                )
            }
            if let historyLimit = configuration.historyLimit, historyLimit < 0 {
                throw AgentError.configurationInvalid(
                    "Foundation Models history limit must not be negative"
                )
            }
        }

        static func descriptor(
            modelIdentifier: String,
            tools: [any FoundationModels.Tool],
            transcript: Transcript,
            configuration: FoundationModelsProfileConfiguration
        ) -> FoundationModelsProfileDescriptor {
            FoundationModelsProfileDescriptor(
                profileIdentifier: configuration.identifier,
                modelIdentifier: modelIdentifier,
                selectedToolNames: tools.map(\.name),
                instructions: self.instructions(from: transcript),
                maximumResponseTokens: configuration.maximumResponseTokens,
                historyLimit: configuration.historyLimit,
                transcriptErrorHandling: configuration.transcriptErrorHandling,
                hasLifecycleHandler: configuration.lifecycleHandler != nil
            )
        }

        static func history(
            from transcript: Transcript,
            limit: Int?
        ) -> [Transcript.Entry] {
            let entries = transcript.filter { entry in
                if case .instructions = entry {
                    return false
                }
                return true
            }
            guard let limit else {
                return entries
            }
            guard limit > 0 else {
                return []
            }
            var start = max(0, entries.count - limit)
            if case .toolOutput = entries[start],
               let toolCallsIndex = entries[..<start].lastIndex(where: { entry in
                   if case .toolCalls = entry {
                       return true
                   }
                   return false
               }) {
                start = toolCallsIndex
            }
            return Array(entries[start...])
        }

        // MARK: Private

        private static func instructions(from transcript: Transcript) -> String? {
            let parts = transcript.compactMap { entry -> String? in
                guard case let .instructions(instructions) = entry else {
                    return nil
                }
                return instructions.segments.compactMap { segment -> String? in
                    guard case let .text(text) = segment else {
                        return nil
                    }
                    return text.content
                }
                .joined()
            }
            .filter { !$0.isEmpty }
            guard !parts.isEmpty else {
                return nil
            }
            return parts.joined(separator: "\n\n")
        }
    }

    #if compiler(>=6.4)
        @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
        @available(tvOS, unavailable)
        extension FoundationModelsDynamicProfileFactory {
            static func makeSession(
                model: any LanguageModel,
                modelIdentifier: String,
                tools: [any FoundationModels.Tool],
                transcript: Transcript,
                configuration: FoundationModelsProfileConfiguration
            ) throws -> LanguageModelSession {
                try self.validate(configuration)
                let descriptor = self.descriptor(
                    modelIdentifier: modelIdentifier,
                    tools: tools,
                    transcript: transcript,
                    configuration: configuration
                )
                let instructionText = self.instructions(from: transcript)
                let history = self.history(
                    from: transcript,
                    limit: configuration.historyLimit
                )
                let policy: TranscriptErrorHandlingPolicy =
                    switch configuration.transcriptErrorHandling {
                    case .revert: .revertTranscript
                    case .preserve: .preserveTranscript
                    }
                let handler = configuration.lifecycleHandler
                let profile = LanguageModelSession.Profile {
                    if let instructionText {
                        Instructions(instructionText)
                    }
                    tools
                }
                .model(model)
                .maximumResponseTokens(configuration.maximumResponseTokens)
                .historyTransform { entries in
                    let transcript = Transcript(entries: entries)
                    return self.history(from: transcript, limit: configuration.historyLimit)
                }
                .transcriptErrorHandlingPolicy(policy)
                .onPrompt { await handler?(.prompt, descriptor) }
                .onResponse { await handler?(.response, descriptor) }
                .onReasoning { await handler?(.reasoning, descriptor) }
                .onToolCall { await handler?(.toolCall, descriptor) }
                .onToolOutput { await handler?(.toolOutput, descriptor) }
                .onActivate { await handler?(.activated, descriptor) }
                .onDeactivate { await handler?(.deactivated, descriptor) }
                return LanguageModelSession(profile: profile, history: history)
            }
        }
    #endif
#endif
