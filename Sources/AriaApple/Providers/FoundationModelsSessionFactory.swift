#if canImport(FoundationModels)
    import Aria
    import FoundationModels

    @available(iOS 26.0, macOS 26.0, *)
    struct FoundationModelsSessionRequirements: OptionSet, Sendable, Equatable {
        let rawValue: UInt8

        static let vision = Self(rawValue: 1 << 0)
        static let guidedGeneration = Self(rawValue: 1 << 1)
        static let toolCalling = Self(rawValue: 1 << 2)
    }

    @available(iOS 26.0, macOS 26.0, *)
    struct FoundationModelsSessionFactory: Sendable {
        typealias Validator = @Sendable (
            FoundationModelsSessionRequirements
        ) throws -> Void
        typealias Builder = @Sendable (
            [any FoundationModels.Tool],
            Transcript,
            FoundationModelsSessionRequirements
        ) throws -> LanguageModelSession

        init(
            validate: @escaping Validator,
            build: @escaping Builder
        ) {
            self.validate = validate
            self.build = build
        }

        static let systemDefault = Self(
            validate: { _ in
                try FoundationModelsProvider.checkAvailability()
            },
            build: { tools, transcript, _ in
                LanguageModelSession(tools: tools, transcript: transcript)
            }
        )

        func makeSession(
            tools: [any FoundationModels.Tool],
            transcript: Transcript,
            requirements: FoundationModelsSessionRequirements
        ) throws -> LanguageModelSession {
            try self.validate(requirements)
            return try self.build(tools, transcript, requirements)
        }

        private let validate: Validator
        private let build: Builder
    }

#if compiler(>=6.4)
    @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
    @available(tvOS, unavailable)
    extension FoundationModelsSessionFactory {
        static func injected<Model: LanguageModel>(
            model: Model,
            declaredCapabilities: ProviderCapabilities
        ) -> Self {
            let availableCapabilities = model.capabilities
            return Self(
                validate: { requested in
                    try Self.validate(
                        declared: declaredCapabilities,
                        available: availableCapabilities,
                        requested: requested
                    )
                },
                build: { tools, transcript, _ in
                    LanguageModelSession(
                        model: model,
                        tools: tools,
                        transcript: transcript
                    )
                }
            )
        }

        static func validate(
            declared: ProviderCapabilities,
            available: LanguageModelCapabilities,
            requested: FoundationModelsSessionRequirements
        ) throws {
            var required = requested
            if declared.supportsVision {
                required.insert(.vision)
            }
            if declared.supportsStructuredOutput {
                required.insert(.guidedGeneration)
            }
            if declared.supportsToolUse {
                required.insert(.toolCalling)
            }

            let checks: [(
                FoundationModelsSessionRequirements,
                LanguageModelCapabilities.Capability,
                String
            )] = [
                (.vision, .vision, "vision"),
                (.guidedGeneration, .guidedGeneration, "structured output"),
                (.toolCalling, .toolCalling, "tool calling"),
            ]
            let missing = checks.compactMap { requirement, capability, name in
                required.contains(requirement) && !available.contains(capability)
                    ? name
                    : nil
            }
            guard missing.isEmpty else {
                throw AgentError.configurationInvalid(
                    "Language model does not support: \(missing.joined(separator: ", "))"
                )
            }
        }
    }
#endif
#endif
