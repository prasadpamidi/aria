#if canImport(FoundationModels) && (os(iOS) || os(macOS) || os(watchOS) || os(tvOS) || os(visionOS))
    import Aria
    @testable import AriaApple
    import FoundationModels
    import XCTest

    @available(iOS 26.0, macOS 26.0, *)
    final class FoundationModelsDynamicProfileFactoryTests: XCTestCase {
        func testDescriptorCapturesEffectiveProfileInputs() {
            let transcript = FoundationModelsProvider.buildTranscript(
                history: [
                    .system("Classify the meal."),
                    .user("A bowl of lentil soup."),
                ],
                defaultInstructions: "Return one category.",
                toolDefinitions: []
            )
            let configuration = FoundationModelsProfileConfiguration(
                identifier: "food-classifier-v1",
                maximumResponseTokens: 128,
                historyLimit: 1,
                transcriptErrorHandling: .preserve,
                lifecycleHandler: { _, _ in }
            )

            let descriptor = FoundationModelsDynamicProfileFactory.descriptor(
                modelIdentifier: "apple.foundationmodels.classifier",
                tools: [SessionFactoryTestTool()],
                transcript: transcript,
                configuration: configuration
            )

            XCTAssertEqual(descriptor.profileIdentifier, "food-classifier-v1")
            XCTAssertEqual(descriptor.modelIdentifier, "apple.foundationmodels.classifier")
            XCTAssertEqual(descriptor.selectedToolNames, ["session_factory_test"])
            XCTAssertEqual(
                descriptor.instructions,
                "Return one category.\n\nClassify the meal."
            )
            XCTAssertEqual(descriptor.maximumResponseTokens, 128)
            XCTAssertEqual(descriptor.historyLimit, 1)
            XCTAssertEqual(descriptor.transcriptErrorHandling, .preserve)
            XCTAssertTrue(descriptor.hasLifecycleHandler)
        }

        func testHistoryDropsInstructionsAndKeepsConfiguredSuffix() {
            let transcript = FoundationModelsProvider.buildTranscript(
                history: [
                    .system("Use the requested format."),
                    .user("first"),
                    .assistant("second"),
                    .user("third"),
                ],
                defaultInstructions: nil,
                toolDefinitions: []
            )

            let history = FoundationModelsDynamicProfileFactory.history(
                from: transcript,
                limit: 2
            )

            XCTAssertEqual(history.count, 2)
            XCTAssertEqual(entryKind(history[0]), "response")
            XCTAssertEqual(entryKind(history[1]), "prompt")
        }

        func testNilHistoryLimitKeepsAllNonInstructionEntries() {
            let transcript = FoundationModelsProvider.buildTranscript(
                history: [
                    .system("Be concise."),
                    .user("first"),
                    .assistant("second"),
                ],
                defaultInstructions: nil,
                toolDefinitions: []
            )

            let history = FoundationModelsDynamicProfileFactory.history(
                from: transcript,
                limit: nil
            )

            XCTAssertEqual(history.count, 2)
            XCTAssertEqual(entryKind(history[0]), "prompt")
            XCTAssertEqual(entryKind(history[1]), "response")
        }

        func testHistoryLimitDoesNotOrphanToolOutput() {
            let call = ToolCall(
                id: "weather-1",
                name: "weather",
                arguments: .object(["city": .string("Cupertino")])
            )
            let transcript = FoundationModelsProvider.buildTranscript(
                history: [
                    .user("Check the weather."),
                    .assistant("", toolCalls: [call]),
                    .tool(callId: call.id, text: "Sunny"),
                    .assistant("It is sunny."),
                ],
                defaultInstructions: nil,
                toolDefinitions: []
            )

            let history = FoundationModelsDynamicProfileFactory.history(
                from: transcript,
                limit: 2
            )

            XCTAssertEqual(history.count, 3)
            XCTAssertEqual(entryKind(history[0]), "toolCalls")
            XCTAssertEqual(entryKind(history[1]), "toolOutput")
            XCTAssertEqual(entryKind(history[2]), "response")
        }

        func testInvalidProfileValuesAreRejectedBeforeSessionConstruction() {
            let configurations = [
                FoundationModelsProfileConfiguration(identifier: ""),
                FoundationModelsProfileConfiguration(
                    identifier: "invalid-response-limit",
                    maximumResponseTokens: 0
                ),
                FoundationModelsProfileConfiguration(
                    identifier: "invalid-history-limit",
                    historyLimit: -1
                ),
            ]

            for configuration in configurations {
                XCTAssertThrowsError(
                    try FoundationModelsDynamicProfileFactory.validate(configuration)
                ) { error in
                    guard case AgentError.configurationInvalid = error else {
                        return XCTFail("Expected configurationInvalid, got \(error)")
                    }
                }
            }
        }

        #if compiler(>=6.4)
            @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
            @available(tvOS, unavailable)
            func testDynamicProfileConstructsARealSession() throws {
                guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) else {
                    throw XCTSkip("Requires iOS 27 / macOS 27 runtime")
                }
                let transcript = FoundationModelsProvider.buildTranscript(
                    history: [.user("previous prompt"), .assistant("previous response")],
                    defaultInstructions: "Be concise.",
                    toolDefinitions: []
                )

                let session = try FoundationModelsDynamicProfileFactory.makeSession(
                    model: SystemLanguageModel.default,
                    modelIdentifier: "apple.foundationmodels.default",
                    tools: [],
                    transcript: transcript,
                    configuration: .init(
                        identifier: "dynamic-profile-construction",
                        maximumResponseTokens: 64,
                        historyLimit: 1,
                        transcriptErrorHandling: .revert
                    )
                )

                XCTAssertEqual(session.transcript.count, 2)
                XCTAssertEqual(entryKind(session.transcript[0]), "instructions")
                XCTAssertEqual(entryKind(session.transcript[1]), "response")
            }
        #endif

        private func entryKind(_ entry: Transcript.Entry) -> String {
            switch entry {
            case .instructions: "instructions"
            case .prompt: "prompt"
            case .toolCalls: "toolCalls"
            case .toolOutput: "toolOutput"
            case .response: "response"
            #if compiler(>=6.4)
                case .reasoning: "reasoning"
            #endif
            @unknown default: "unknown"
            }
        }
    }
#endif
