#if canImport(FoundationModels) && (os(iOS) || os(macOS) || os(watchOS) || os(tvOS) || os(visionOS))

    import Foundation
    import FoundationModels
    import XCTest
    @testable import Aria
    @testable import AriaApple

    @available(iOS 26.0, macOS 26.0, *)
    @Generable
    private struct TestQuote {
        @Guide(description: "A short fictional quote, fewer than 12 words")
        var text: String
        @Guide(description: "A made-up speaker name")
        var speaker: String
    }

    @available(iOS 26.0, macOS 26.0, *)
    final class FoundationModelsStructuredTests: XCTestCase {
        // MARK: - Provider-level error paths

        func testStreamStructuredThrowsOnEmptyMessages() async {
            let provider = FoundationModelsProvider()
            do {
                for try await _ in provider.streamStructured(
                    messages: [], as: TestQuote.self
                ) { }
                XCTFail("Expected configurationInvalid")
            } catch let error as AgentError {
                guard case .configurationInvalid = error else {
                    XCTFail("Expected configurationInvalid, got \(error)")
                    return
                }
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }

        // MARK: - Agent extension surface

        func testAgentRespondReturnsConfigErrorWhenProviderIsNotFM() async {
            let agent = Agent(config: AgentConfig(
                provider: NotFMProvider(),
                tools: [],
                threadId: "t"
            ))
            do {
                for try await _ in agent.respond(
                    .message(.user("hi")), as: TestQuote.self
                ) { }
                XCTFail("Expected configurationInvalid")
            } catch let error as AgentError {
                guard case .configurationInvalid = error else {
                    XCTFail("Expected configurationInvalid, got \(error)")
                    return
                }
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }

        // MARK: - Smoke test (requires real model availability)

        func testStreamStructuredEmitsPartialsAndFinishWhenModelAvailable() async throws {
            try XCTSkipIf(
                SystemLanguageModel.default.availability != .available,
                "FoundationModels system model is not available on this runner"
            )

            let provider = FoundationModelsProvider()
            var sawPartial = false
            var finalQuote: TestQuote?
            for try await event in provider.streamStructured(
                messages: [.user("Give me one short quote.")],
                as: TestQuote.self
            ) {
                switch event {
                case .partial: sawPartial = true
                case let .finish(quote): finalQuote = quote
                case .toolCallExecuted: break
                }
            }
            XCTAssertTrue(sawPartial, "Expected at least one partial snapshot")
            let final = try XCTUnwrap(finalQuote, "Expected finish event with a quote")
            XCTAssertFalse(final.text.isEmpty, "Final quote text was empty")
            XCTAssertFalse(final.speaker.isEmpty, "Final quote speaker was empty")
        }
    }

    // MARK: - Stand-in provider for negative tests

    private struct NotFMProvider: LLMProvider {
        let capabilities = ProviderCapabilities(
            modelIdentifier: "test.notfm",
            supportsStreaming: true,
            supportsToolUse: false,
            supportsParallelToolCalls: false,
            supportsVision: false,
            supportsAudio: false,
            supportsStructuredOutput: false,
            supportsSystemPrompt: true,
            maxContextTokens: nil
        )

        func stream(
            messages _: [Message],
            tools _: [ToolDefinition],
            options _: Aria.GenerationOptions
        ) -> AsyncThrowingStream<ProviderEvent, any Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

#endif
