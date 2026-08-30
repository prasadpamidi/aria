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
#endif
