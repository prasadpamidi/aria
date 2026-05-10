#if canImport(FoundationModels) && (os(iOS) || os(macOS) || os(watchOS) || os(tvOS) || os(visionOS))

    import Foundation
    import FoundationModels
    import XCTest
    @testable import Aria
    @testable import AriaApple

    @available(iOS 26.0, macOS 26.0, *)
    final class FoundationModelsProviderTests: XCTestCase {
        // MARK: - Prompt extraction

        func testExtractPromptUsesLastMessageText() throws {
            let messages: [Message] = [
                .user("first"),
                .assistant("hello"),
                .user("ask me again")
            ]
            let (prompt, history) = try FoundationModelsProvider.extractPrompt(from: messages)
            XCTAssertEqual(prompt, "ask me again")
            XCTAssertEqual(history.map(\.textContent), ["first", "hello"])
        }

        func testExtractPromptThrowsWhenLastMessageIsEmpty() {
            let messages: [Message] = [
                .user("first"),
                .user("")
            ]
            XCTAssertThrowsError(try FoundationModelsProvider.extractPrompt(from: messages)) { error in
                guard let agentError = error as? AgentError,
                      case .configurationInvalid = agentError else {
                    XCTFail("Expected configurationInvalid, got \(error)")
                    return
                }
            }
        }

        func testExtractPromptThrowsOnEmptyInput() {
            XCTAssertThrowsError(try FoundationModelsProvider.extractPrompt(from: [])) { error in
                guard let agentError = error as? AgentError,
                      case .configurationInvalid = agentError else {
                    XCTFail("Expected configurationInvalid, got \(error)")
                    return
                }
            }
        }

        // MARK: - Transcript construction

        func testBuildTranscriptCollapsesSystemMessagesIntoInstructions() {
            let history: [Message] = [
                .system("Be concise."),
                .system("Answer in English."),
            ]
            let transcript = FoundationModelsProvider.buildTranscript(
                history: history,
                defaultInstructions: "You are an assistant.",
                toolDefinitions: []
            )
            XCTAssertEqual(transcript.count, 1)
            guard case let .instructions(instructions) = transcript.first else {
                XCTFail("Expected instructions entry")
                return
            }
            // Three lines joined by blank lines.
            let combined = instructions.segments.compactMap { segment -> String? in
                if case let .text(text) = segment {
                    text.content
                } else {
                    nil
                }
            }
            .joined()
            XCTAssertTrue(combined.contains("You are an assistant."))
            XCTAssertTrue(combined.contains("Be concise."))
            XCTAssertTrue(combined.contains("Answer in English."))
        }

        func testBuildTranscriptMapsRolesToCorrectEntryKinds() {
            let history: [Message] = [
                .user("hi"),
                .assistant("hello"),
                .user("bye")
            ]
            let transcript = FoundationModelsProvider.buildTranscript(
                history: history,
                defaultInstructions: nil,
                toolDefinitions: []
            )
            XCTAssertEqual(transcript.count, 3)
            XCTAssertTrue(transcriptEntryKind(transcript[0]) == "prompt")
            XCTAssertTrue(transcriptEntryKind(transcript[1]) == "response")
            XCTAssertTrue(transcriptEntryKind(transcript[2]) == "prompt")
        }

        func testBuildTranscriptEmitsToolCallsAndOutputs() {
            let call = ToolCall(
                id: "c1",
                name: "echo",
                arguments: .object(["msg": .string("hi")])
            )
            let history: [Message] = [
                .user("call echo"),
                .assistant("calling now", toolCalls: [call]),
                .tool(callId: "c1", text: "{\"echoed\":\"hi\"}")
            ]
            let transcript = FoundationModelsProvider.buildTranscript(
                history: history,
                defaultInstructions: nil,
                toolDefinitions: []
            )
            // prompt, response (text), toolCalls, toolOutput → 4 entries.
            XCTAssertEqual(transcript.count, 4)

            guard case let .toolOutput(output) = transcript[3] else {
                XCTFail("Expected last entry to be toolOutput")
                return
            }
            XCTAssertEqual(output.toolName, "echo", "tool name should be reconstructed from prior assistant call")
            XCTAssertEqual(output.id, "c1")
        }

        func testBuildTranscriptOmitsInstructionsWhenEverythingIsEmpty() {
            let transcript = FoundationModelsProvider.buildTranscript(
                history: [],
                defaultInstructions: nil,
                toolDefinitions: []
            )
            XCTAssertTrue(transcript.isEmpty)
        }

        // MARK: - Capabilities

        func testDefaultCapabilities() {
            let provider = FoundationModelsProvider()
            XCTAssertTrue(provider.capabilities.supportsStreaming)
            XCTAssertTrue(provider.capabilities.supportsSystemPrompt)
            XCTAssertTrue(provider.capabilities.supportsToolUse)
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
            var streamedText = ""
            for event in events {
                switch event {
                case .messageStart: sawStart = true
                case let .textDelta(chunk):
                    sawDelta = true
                    streamedText += chunk
                case .messageStop: sawStop = true
                default: break
                }
            }
            XCTAssertTrue(sawStart, "Expected messageStart event")
            XCTAssertTrue(sawDelta, "Expected at least one textDelta")
            XCTAssertTrue(sawStop, "Expected messageStop event")
            XCTAssertFalse(
                streamedText.contains("User:") || streamedText.contains("Assistant:"),
                "Transcript-style prefixes leaked into the response: \(streamedText)"
            )
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

    // MARK: - Helpers

    @available(iOS 26.0, macOS 26.0, *)
    private func transcriptEntryKind(_ entry: Transcript.Entry) -> String {
        switch entry {
        case .instructions: "instructions"
        case .prompt: "prompt"
        case .response: "response"
        case .toolCalls: "toolCalls"
        case .toolOutput: "toolOutput"
        @unknown default: "unknown"
        }
    }

#endif
