import Foundation
import XCTest
@testable import Aria
@testable import AriaTesting

// MARK: - EchoTool

private struct EchoTool: Tool {
    struct Input: Codable {
        let message: String
    }

    struct Output: Codable {
        let echoed: String
    }

    static let name = "echo"
    static let description = "Echoes a message back."

    static var inputSchema: JSONSchema {
        .object(properties: ["message": .string()], required: ["message"])
    }

    func call(_ input: Input, context _: ToolContext) async throws -> Output {
        Output(echoed: input.message)
    }
}

// MARK: - CountingMiddleware

private struct CountingMiddleware: AgentMiddleware {
    actor Counter {
        var beforeRun = 0
        var beforeStep = 0
        var afterStep = 0
        var afterRun = 0

        func bumpBeforeRun() {
            self.beforeRun += 1
        }

        func bumpBeforeStep() {
            self.beforeStep += 1
        }

        func bumpAfterStep() {
            self.afterStep += 1
        }

        func bumpAfterRun() {
            self.afterRun += 1
        }
    }

    let counter: Counter

    func beforeRun(_ state: AgentState) async throws -> AgentState {
        await self.counter.bumpBeforeRun()
        return state
    }

    func beforeStep(_ state: AgentState) async throws -> AgentState {
        await self.counter.bumpBeforeStep()
        return state
    }

    func afterStep(_ state: AgentState) async throws -> AgentState {
        await self.counter.bumpAfterStep()
        return state
    }

    func afterRun(_ state: AgentState, finalEvent _: AgentEvent) async throws -> AgentState {
        await self.counter.bumpAfterRun()
        return state
    }
}

// MARK: - AgentTests

final class AgentTests: XCTestCase {
    // MARK: Internal

    func testSingleStepRunWithNoToolCalls() async throws {
        let provider = MockLLMProvider(scenes: [.text("Hello there.")])
        let agent = Agent(config: AgentConfig(provider: provider))

        let events = try await collect(agent.stream(.message(.user("Hi"))))

        XCTAssertTrue(events.contains { event in
            if case let .userMessageReceived(msg) = event {
                msg.textContent == "Hi"
            } else {
                false
            }
        })
        XCTAssertTrue(events.contains { event in
            if case .stepStart(0) = event {
                true
            } else {
                false
            }
        })
        XCTAssertTrue(events.contains { event in
            if case let .textDelta(chunk) = event {
                chunk == "Hello there."
            } else {
                false
            }
        })
        XCTAssertTrue(events.contains { event in
            if case .stepEnd(0) = event {
                true
            } else {
                false
            }
        })
        XCTAssertTrue(events.contains { event in
            if case let .finish(reason) = event {
                reason == .endTurn
            } else {
                false
            }
        })
    }

    func testToolCallExecutesToolAndContinues() async throws {
        let provider = MockLLMProvider(scenes: [
            .toolCall(
                id: "call-1",
                name: "echo",
                arguments: .object(["message": .string("ping")])
            ),
            .text("Done.", finishReason: .endTurn)
        ])
        let agent = Agent(config: AgentConfig(
            provider: provider,
            tools: [AnyTool(EchoTool())]
        ))

        let events = try await collect(agent.stream(.message(.user("call echo"))))

        let hasToolStart = events.contains { event in
            if case let .toolExecutionStart(id) = event {
                id == "call-1"
            } else {
                false
            }
        }
        let toolEndResult: ToolExecutionResult? = events.compactMap { event in
            if case let .toolExecutionEnd(_, result) = event {
                result
            } else {
                nil
            }
        }
        .first

        XCTAssertTrue(hasToolStart, "Expected toolExecutionStart event")
        XCTAssertNotNil(toolEndResult)
        XCTAssertFalse(toolEndResult?.isError ?? true)
        XCTAssertEqual(toolEndResult?.output.objectValue?["echoed"], .string("ping"))
        XCTAssertEqual(provider.invocations.count, 2)
    }

    func testMaxStepsTerminatesWithMaxStepsReached() async throws {
        let provider = MockLLMProvider(scenes: [
            .toolCall(
                id: "c1",
                name: "echo",
                arguments: .object(["message": .string("loop")])
            ),
            .toolCall(
                id: "c2",
                name: "echo",
                arguments: .object(["message": .string("loop")])
            ),
            .toolCall(
                id: "c3",
                name: "echo",
                arguments: .object(["message": .string("loop")])
            )
        ])
        let agent = Agent(config: AgentConfig(
            provider: provider,
            tools: [AnyTool(EchoTool())],
            maxSteps: 2
        ))

        let events = try await collect(agent.stream(.message(.user("loop"))))

        let finishEvent = events.last { event in
            if case .finish = event {
                true
            } else {
                false
            }
        }
        if case let .finish(reason) = finishEvent {
            XCTAssertEqual(reason, .maxStepsReached)
        } else {
            XCTFail("Expected finish event with maxStepsReached")
        }
    }

    func testToolsConfiguredOnNonToolProviderThrowsConfigurationInvalid() async {
        let capabilities = ProviderCapabilities(
            modelIdentifier: "no-tools",
            supportsToolUse: false
        )
        let provider = MockLLMProvider(scenes: [.text("hi")], capabilities: capabilities)
        let agent = Agent(config: AgentConfig(
            provider: provider,
            tools: [AnyTool(EchoTool())]
        ))

        do {
            _ = try await self.collect(agent.stream(.message(.user("hi"))))
            XCTFail("Expected configurationInvalid error")
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

    func testMiddlewareLifecycleHooksFire() async throws {
        let counter = CountingMiddleware.Counter()
        let middleware = CountingMiddleware(counter: counter)
        let provider = MockLLMProvider(scenes: [.text("done")])
        let agent = Agent(config: AgentConfig(
            provider: provider,
            middleware: [middleware]
        ))

        _ = try await self.collect(agent.stream(.message(.user("hi"))))

        let beforeRun = await counter.beforeRun
        let beforeStep = await counter.beforeStep
        let afterStep = await counter.afterStep
        let afterRun = await counter.afterRun
        XCTAssertEqual(beforeRun, 1)
        XCTAssertEqual(beforeStep, 1)
        XCTAssertEqual(afterStep, 1)
        XCTAssertEqual(afterRun, 1)
    }

    func testUnknownToolNameSurfacesAsError() async throws {
        let provider = MockLLMProvider(scenes: [
            .toolCall(id: "c1", name: "missing", arguments: .null)
        ])
        let agent = Agent(config: AgentConfig(
            provider: provider,
            tools: [AnyTool(EchoTool())]
        ))

        do {
            _ = try await self.collect(agent.stream(.message(.user("call missing"))))
            XCTFail("Expected toolNotFound error")
        } catch let error as AgentError {
            if case let .toolNotFound(name) = error {
                XCTAssertEqual(name, "missing")
            } else {
                XCTFail("Expected toolNotFound, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCancellationStopsAgent() async throws {
        let provider = MockLLMProvider(scenes: [.text("hi")])
        let agent = Agent(config: AgentConfig(provider: provider))

        let task = Task {
            try await self.collect(agent.stream(.message(.user("hi"))))
        }
        task.cancel()

        do {
            _ = try await task.value
        } catch is AgentError {
            // expected: cancellation surfaces as AgentError.cancelled
        } catch is CancellationError {
            // also acceptable
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: Private

    // MARK: - Helpers

    private func collect(
        _ stream: AsyncThrowingStream<AgentEvent, any Error>
    ) async throws -> [AgentEvent] {
        var result: [AgentEvent] = []
        for try await event in stream {
            result.append(event)
        }
        return result
    }
}
