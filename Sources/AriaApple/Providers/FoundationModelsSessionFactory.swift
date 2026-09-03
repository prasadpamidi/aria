#if canImport(FoundationModels)
    import Aria
    import FoundationModels

    @available(iOS 26.0, macOS 26.0, *)
    struct FoundationModelsSessionRequirements: OptionSet, Equatable {
        static let vision = Self(rawValue: 1 << 0)
        static let guidedGeneration = Self(rawValue: 1 << 1)
        static let toolCalling = Self(rawValue: 1 << 2)

        let rawValue: UInt8
    }

    @available(iOS 26.0, macOS 26.0, *)
    struct FoundationModelsSessionFactory {
        // MARK: Lifecycle

        init(
            validate: @escaping Validator,
            build: @escaping Builder
        ) {
            self.validate = validate
            self.build = build
        }

        // MARK: Internal

        typealias Validator = @Sendable (
            FoundationModelsSessionRequirements
        ) throws -> Void
        typealias Builder = @Sendable (
            [any FoundationModels.Tool],
            Transcript,
            FoundationModelsSessionRequirements,
            String,
            FoundationModelsProfileConfiguration?
        ) throws -> LanguageModelSession

        static let systemDefault = Self(
            validate: { _ in
                try FoundationModelsProvider.checkAvailability()
            },
            build: { tools, transcript, _, modelIdentifier, profileConfiguration in
                #if compiler(>=6.4)
                    if #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *),
                       let profileConfiguration {
                        return try FoundationModelsDynamicProfileFactory.makeSession(
                            model: SystemLanguageModel.default,
                            modelIdentifier: modelIdentifier,
                            tools: tools,
                            transcript: transcript,
                            configuration: profileConfiguration
                        )
                    }
                #endif
                guard profileConfiguration == nil else {
                    throw AgentError.configurationInvalid(
                        "Foundation Models Dynamic Profiles require iOS 27 or macOS 27"
                    )
                }
                return LanguageModelSession(tools: tools, transcript: transcript)
            }
        )

        func makeSession(
            tools: [any FoundationModels.Tool],
            transcript: Transcript,
            requirements: FoundationModelsSessionRequirements,
            modelIdentifier: String,
            profileConfiguration: FoundationModelsProfileConfiguration?
        ) throws -> LanguageModelSession {
            try self.validate(requirements)
            if let profileConfiguration {
                try FoundationModelsDynamicProfileFactory.validate(profileConfiguration)
            }
            return try self.build(
                tools,
                transcript,
                requirements,
                modelIdentifier,
                profileConfiguration
            )
        }

        // MARK: Private

        private let validate: Validator
        private let build: Builder
    }

    #if compiler(>=6.4)
        @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
        @available(tvOS, unavailable)
        extension FoundationModelsSessionFactory {
            private struct CapabilityCheck {
                let requirement: FoundationModelsSessionRequirements
                let capability: LanguageModelCapabilities.Capability
                let name: String
            }

            static func injected(
                model: some LanguageModel,
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
                    build: { tools, transcript, _, modelIdentifier, profileConfiguration in
                        if let profileConfiguration {
                            return try FoundationModelsDynamicProfileFactory.makeSession(
                                model: model,
                                modelIdentifier: modelIdentifier,
                                tools: tools,
                                transcript: transcript,
                                configuration: profileConfiguration
                            )
                        }
                        return LanguageModelSession(
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

                let checks = [
                    CapabilityCheck(requirement: .vision, capability: .vision, name: "vision"),
                    CapabilityCheck(
                        requirement: .guidedGeneration,
                        capability: .guidedGeneration,
                        name: "structured output"
                    ),
                    CapabilityCheck(
                        requirement: .toolCalling,
                        capability: .toolCalling,
                        name: "tool calling"
                    ),
                ]
                let missing = checks.compactMap { check in
                    required.contains(check.requirement) && !available.contains(check.capability)
                        ? check.name
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
