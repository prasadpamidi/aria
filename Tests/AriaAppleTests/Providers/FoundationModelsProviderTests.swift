#if canImport(FoundationModels) && (os(iOS) || os(macOS) || os(watchOS) || os(tvOS) || os(visionOS))

    import Foundation
    import FoundationModels
    import XCTest
    @testable import Aria
    @testable import AriaApple

    @available(iOS 26.0, macOS 26.0, *)
    final class FoundationModelsProviderTests: XCTestCase {
        // MARK: - Translation (pure, no model boot)

        func testTranslateSeparatesSystemAndConversation() {
            let messages: [Message] = [
                .system("You are a poet."),
                .user("Write a haiku.")
            ]
            let (instructions, prompt) = FoundationModelsProvider.translate(
                messages: messages,
                defaultInstructions: nil
            )
            XCTAssertEqual(instructions, "You are a poet.")
            XCTAssertEqual(prompt, "User: Write a haiku.")
        }

        func testTranslateMergesDefaultWithMessageSystemPrompts() {
            let messages: [Message] = [
                .system("Be concise."),
                .user("Hi.")
            ]
            let (instructions, prompt) = FoundationModelsProvider.translate(
                messages: messages,
                defaultInstructions: "You are a helpful assistant."
            )
            XCTAssertEqual(
                instructions,
                "You are a helpful assistant.\n\nBe concise."
            )
            XCTAssertEqual(prompt, "User: Hi.")
        }

        func testTranslatePreservesMultiTurnConversation() {
            let messages: [Message] = [
                .user("What is 2+2?"),
                .assistant("4"),
                .user("Now multiply by 3.")
            ]
            let (instructions, prompt) = FoundationModelsProvider.translate(
                messages: messages,
                defaultInstructions: nil
            )
            XCTAssertTrue(instructions.isEmpty)
            XCTAssertEqual(
                prompt,
                """
                User: What is 2+2?

                Assistant: 4

                User: Now multiply by 3.
                """
            )
        }

        func testTranslateSkipsEmptyContent() {
            let messages: [Message] = [
                .user("hello"),
                .assistant(""),
                .user("are you there?")
            ]
            let (_, prompt) = FoundationModelsProvider.translate(
                messages: messages,
                defaultInstructions: nil
            )
            XCTAssertEqual(
                prompt,
                """
                User: hello

                User: are you there?
                """
            )
        }

        func testTranslateLabelsToolMessagesWithCallId() {
            let messages: [Message] = [
                .tool(callId: "call-42", text: "result-data")
            ]
            let (_, prompt) = FoundationModelsProvider.translate(
                messages: messages,
                defaultInstructions: nil
            )
            XCTAssertEqual(prompt, "Tool[call-42]: result-data")
        }

        // MARK: - Capabilities

        func testDefaultCapabilities() {
            let provider = FoundationModelsProvider()
            XCTAssertTrue(provider.capabilities.supportsStreaming)
            XCTAssertTrue(provider.capabilities.supportsSystemPrompt)
            XCTAssertTrue(
                provider.capabilities.supportsToolUse,
                "PR 4 enabled tool use via the AriaBridgeTool adapter"
            )
            XCTAssertEqual(
                provider.capabilities.modelIdentifier,
                "apple.foundationmodels.default"
            )
        }

        // MARK: - Smoke test (requires real model availability)

        func testStreamProducesTextDeltasWhenModelAvailable() async throws {
            try XCTSkipIf(
                SystemLanguageModel.default.availability != .available,
                "FoundationModels system model is not available on this runner"
            )

            let provider = FoundationModelsProvider()
            let messages: [Message] = [
                .system("Answer in fewer than 12 words."),
                .user("Say hi.")
            ]

            var events: [ProviderEvent] = []
            for try await event in provider.stream(
                messages: messages,
                tools: [],
                options: .init()
            ) {
                events.append(event)
            }

            XCTAssertFalse(events.isEmpty, "Expected at least one event")

            var sawStart = false
            var sawDelta = false
            var sawStop = false
            for event in events {
                switch event {
                case .messageStart: sawStart = true
                case .textDelta: sawDelta = true
                case .messageStop: sawStop = true
                default: break
                }
            }
            XCTAssertTrue(sawStart, "Expected messageStart event")
            XCTAssertTrue(sawDelta, "Expected at least one textDelta")
            XCTAssertTrue(sawStop, "Expected messageStop event")
        }

        func testStreamThrowsConfigurationErrorWithEmptyMessages() async {
            let provider = FoundationModelsProvider()
            do {
                for try await _ in provider.stream(messages: [], tools: [], options: .init()) { }
                XCTFail("Expected configurationInvalid")
            } catch let error as AgentError {
                if case .configurationInvalid = error {
                    // expected
                } else {
                    XCTFail("Expected configurationInvalid, got \(error)")
                }
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

#endif
