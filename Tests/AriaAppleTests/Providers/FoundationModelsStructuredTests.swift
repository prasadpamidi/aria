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

        // MARK: - Middleware integration

        func testAgentRespondAppliesMiddlewareLifecycle() async throws {
            try XCTSkipIf(
                SystemLanguageModel.default.availability != .available,
                "FoundationModels system model is not available on this runner"
            )

            // RecordingMiddleware captures every lifecycle hook so we
            // can assert the order Agent.respond invoked them in.
            let recorder = HookRecorder()
            let middleware = RecordingMiddleware(recorder: recorder)
            let agent = Agent(config: AgentConfig(
                provider: FoundationModelsProvider(),
                tools: [],
                systemPrompt: "Reply with a short fictional quote.",
                threadId: "t-respond-middleware",
                middleware: [middleware]
            ))

            for try await _ in agent.respond(.message(.user("Quote me.")), as: TestQuote.self) { }

            let hooks = await recorder.calls
            XCTAssertEqual(hooks, ["beforeRun", "beforeStep", "afterStep", "afterRun"])

            // afterStep should see both the original user message and
            // the JSON-encoded assistant final response appended.
            let lastSeenMessages = await recorder.lastMessages
            XCTAssertEqual(lastSeenMessages.first?.role, .user, "User message should be preserved")
            XCTAssertEqual(lastSeenMessages.last?.role, .assistant, "Final assistant message should be appended")
            XCTAssertTrue(
                lastSeenMessages.last?.textContent.contains("\"text\"") ?? false,
                "Final assistant message should be JSON-encoded structured response"
            )
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

    // MARK: - HookRecorder + RecordingMiddleware

    private actor HookRecorder {
        private(set) var calls: [String] = []
        private(set) var lastMessages: [Message] = []

        func record(_ name: String, messages: [Message]) {
            self.calls.append(name)
            self.lastMessages = messages
        }
    }

    private struct RecordingMiddleware: AgentMiddleware {
        let recorder: HookRecorder

        func beforeRun(_ state: AgentState) async throws -> AgentState {
            await self.recorder.record("beforeRun", messages: state.messages)
            return state
        }

        func beforeStep(_ state: AgentState) async throws -> AgentState {
            await self.recorder.record("beforeStep", messages: state.messages)
            return state
        }

        func afterStep(_ state: AgentState) async throws -> AgentState {
            await self.recorder.record("afterStep", messages: state.messages)
            return state
        }

        func afterRun(_ state: AgentState, finalEvent _: AgentEvent) async throws -> AgentState {
            await self.recorder.record("afterRun", messages: state.messages)
            return state
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
