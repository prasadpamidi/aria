#if canImport(FoundationModels) && compiler(>=6.4)
    import Aria
    @testable import AriaApple
    import FoundationModels
    import XCTest

    @available(iOS 27.0, macOS 27.0, *)
    final class FoundationModelsLanguageModelTests: XCTestCase {
        override func setUpWithError() throws {
            guard #available(iOS 27.0, macOS 27.0, *) else {
                throw XCTSkip("Requires iOS 27 / macOS 27 runtime")
            }
        }

        func testInjectedInitializerKeepsDeclaredCapabilities() {
            let declared = ProviderCapabilities(
                modelIdentifier: "test.system-through-language-model",
                supportsStructuredOutput: true
            )

            let provider = FoundationModelsProvider(
                model: SystemLanguageModel.default,
                capabilities: declared
            )

            XCTAssertEqual(provider.capabilities, declared)
        }

        func testValidationRejectsUnsupportedGuidedGeneration() {
            let declared = ProviderCapabilities(
                modelIdentifier: "test.text-only",
                supportsStructuredOutput: true
            )

            XCTAssertThrowsError(
                try FoundationModelsSessionFactory.validate(
                    declared: declared,
                    available: LanguageModelCapabilities([]),
                    requested: []
                )
            ) { error in
                guard case AgentError.configurationInvalid = error else {
                    return XCTFail("Expected configurationInvalid, got \(error)")
                }
            }
        }

        func testValidationRejectsRequestedToolCalling() {
            let declared = ProviderCapabilities(modelIdentifier: "test.text-only")

            XCTAssertThrowsError(
                try FoundationModelsSessionFactory.validate(
                    declared: declared,
                    available: LanguageModelCapabilities([]),
                    requested: [.toolCalling]
                )
            ) { error in
                guard case AgentError.configurationInvalid = error else {
                    return XCTFail("Expected configurationInvalid, got \(error)")
                }
            }
        }

        func testValidationAcceptsRepresentableCapabilities() throws {
            let declared = ProviderCapabilities(
                modelIdentifier: "test.capable",
                supportsToolUse: true,
                supportsVision: true,
                supportsStructuredOutput: true
            )

            try FoundationModelsSessionFactory.validate(
                declared: declared,
                available: LanguageModelCapabilities([
                    .vision,
                    .guidedGeneration,
                    .reasoning,
                    .toolCalling,
                ]),
                requested: [.toolCalling, .guidedGeneration]
            )
        }
    }
#endif
