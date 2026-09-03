#if canImport(FoundationModels) && (os(iOS) || os(macOS) || os(watchOS) || os(tvOS) || os(visionOS))

    import Foundation
    import FoundationModels
    import XCTest
    @testable import Aria
    @testable import AriaApple

    @available(iOS 26.0, macOS 26.0, *)
    final class FoundationModelsErrorMapperTests: XCTestCase {
        override func setUpWithError() throws {
            guard #available(iOS 26.0, macOS 26.0, *) else {
                throw XCTSkip("Requires iOS 26 / macOS 26 runtime")
            }
        }

        func testCancellationStaysCancellation() {
            XCTAssertEqual(
                FoundationModelsErrorMapper.map(CancellationError()),
                .cancelled
            )
        }

        func testExistingAgentErrorPassesThroughUnchanged() {
            let expected = AgentError.configurationInvalid("bad configuration")
            XCTAssertEqual(FoundationModelsErrorMapper.map(expected), expected)
        }

        func testUnknownErrorPreservesTypeAndMessage() {
            let mapped = FoundationModelsErrorMapper.map(TestError.failure)
            guard case let .providerRejected(failure) = mapped else {
                return XCTFail("Expected typed provider rejection, got \(mapped)")
            }

            XCTAssertEqual(failure.kind, .unknown)
            XCTAssertEqual(failure.underlying?.typeName, "TestError")
            XCTAssertTrue(failure.underlying?.message.contains("failure") == true)
        }

        func testUnavailableReasonsMapToActionableKinds() {
            XCTAssertEqual(
                FoundationModelsErrorMapper.mapUnavailable(.deviceNotEligible).failureKind,
                .providerUnavailable
            )
            XCTAssertEqual(
                FoundationModelsErrorMapper.mapUnavailable(.appleIntelligenceNotEnabled).failureKind,
                .providerUnavailable
            )
            XCTAssertEqual(
                FoundationModelsErrorMapper.mapUnavailable(.modelNotReady).failureKind,
                .assetsUnavailable
            )
        }

        #if compiler(>=6.4)
            @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
            func testLanguageModelErrorsMapToStableKinds() throws {
                guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) else {
                    throw XCTSkip("Requires iOS 27 / macOS 27 runtime")
                }
                let cases: [(any Error, ProviderFailureKind)] = [
                    (
                        LanguageModelError.contextSizeExceeded(.init(
                            contextSize: 4096,
                            tokenCount: 4097,
                            debugDescription: "too many tokens"
                        )),
                        .contextWindowExceeded
                    ),
                    (
                        LanguageModelError.rateLimited(.init(
                            resetDate: nil,
                            debugDescription: "slow down"
                        )),
                        .rateLimited
                    ),
                    (
                        LanguageModelError.guardrailViolation(.init(
                            debugDescription: "guardrail"
                        )),
                        .safetyRejected
                    ),
                    (
                        LanguageModelError.refusal(.init(
                            explanation: "cannot comply",
                            debugDescription: "refused"
                        )),
                        .safetyRejected
                    ),
                    (
                        LanguageModelError.unsupportedCapability(.init(
                            capability: .vision,
                            debugDescription: "no images"
                        )),
                        .unsupportedCapability
                    ),
                    (
                        LanguageModelError.unsupportedTranscriptContent(.init(
                            unsupportedContent: [],
                            debugDescription: "bad transcript"
                        )),
                        .unsupportedTranscript
                    ),
                    (
                        LanguageModelError.unsupportedGenerationGuide(.init(
                            schemaName: "Food",
                            debugDescription: "bad guide"
                        )),
                        .unsupportedGenerationGuide
                    ),
                    (
                        LanguageModelError.unsupportedLanguageOrLocale(.init(
                            languageCode: .english,
                            debugDescription: "unsupported language"
                        )),
                        .unsupportedLanguageOrLocale
                    ),
                    (
                        LanguageModelError.timeout(.init(debugDescription: "timed out")),
                        .timedOut
                    ),
                ]

                for (error, expectedKind) in cases {
                    XCTAssertEqual(
                        FoundationModelsErrorMapper.map(error).failureKind,
                        expectedKind
                    )
                }
            }

            @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
            func testSystemAndSessionErrorsMapToStableKinds() throws {
                guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) else {
                    throw XCTSkip("Requires iOS 27 / macOS 27 runtime")
                }
                let cases: [(any Error, ProviderFailureKind)] = [
                    (
                        SystemLanguageModel.Error.assetsUnavailable(.init(
                            debugDescription: "assets missing"
                        )),
                        .assetsUnavailable
                    ),
                    (LanguageModelSession.Error.concurrentRequests, .sessionConflict),
                    (LanguageModelSession.Error.transcriptMutationWhileResponding, .transcriptMutation),
                ]

                for (error, expectedKind) in cases {
                    XCTAssertEqual(
                        FoundationModelsErrorMapper.map(error).failureKind,
                        expectedKind
                    )
                }
            }
        #endif
    }

    private extension AgentError {
        var failureKind: ProviderFailureKind? {
            guard case let .providerRejected(failure) = self else {
                return nil
            }
            return failure.kind
        }
    }

    private enum TestError: Error {
        case failure
    }

#endif
