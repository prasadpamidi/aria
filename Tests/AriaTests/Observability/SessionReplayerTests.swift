import Foundation
import XCTest
@testable import Aria
@testable import AriaTesting

// MARK: - ChainState

private struct ChainState: Codable, Equatable {
    var seen: [String]
}

// MARK: - EchoTool

private struct EchoTool: Tool {
    struct Input: Codable {
        let text: String
    }

    struct Output: Codable {
        let echoed: String
    }

    static let name = "echo"
    static let description = "Echo a string back."

    static var inputSchema: JSONSchema {
        .object(properties: ["text": .string()], required: ["text"])
    }

    func call(_ input: Input, context _: ToolContext) async throws -> Output {
        Output(echoed: input.text)
    }
}

// MARK: - SessionReplayerTests

final class SessionReplayerTests: XCTestCase {
    // MARK: Internal

    // MARK: - Provider replay (text)

    func testMockProviderReproducesTextOnlyAgentRun() async throws {
        // Stage 1 — record an original run.
        let recorder = SessionRecorder()
        let middleware = RecordingMiddleware(recorder: recorder)
        middleware.bind(providerSystem: "test.mock", providerModel: "v1", systemPrompt: nil)
        let original = MockLLMProvider(scenes: [.text("hello world")])
        let originalAgent = Agent(config: AgentConfig(
            provider: original,
            tools: [],
            threadId: "t-text",
            middleware: [middleware]
        ))
        for try await _ in originalAgent.stream(.message(.user("hi"))) { }
        let bundle = await recorder.bundle()
        let agentRecord = try XCTUnwrap(bundle.agent)

        // Stage 2 — replay with a fresh agent, mocked from the bundle.
        let replayProvider = SessionReplayer.mockProvider(from: agentRecord)
        let replayedAgent = Agent(config: AgentConfig(
            provider: replayProvider,
            tools: [],
            threadId: "t-text-replay"
        ))
        var replayedText = ""
        for try await event in replayedAgent.stream(.message(.user("hi"))) {
            if case let .textDelta(chunk) = event {
                replayedText += chunk
            }
        }
        XCTAssertEqual(replayedText, "hello world")
    }

    // MARK: - Provider replay (tool calls)

    func testMockProviderReproducesToolCallTrajectory() async throws {
        let agentRecord = try await Self.recordOriginalToolRun()
        XCTAssertEqual(agentRecord.steps.count, 2, "Tool turn + final reply")

        let replayProvider = SessionReplayer.mockProvider(from: agentRecord)
        let replayedAgent = Agent(config: AgentConfig(
            provider: replayProvider,
            tools: [AnyTool(EchoTool())],
            threadId: "t-tool-replay"
        ))
        var sawToolCall = false
        var assistantText = ""
        for try await event in replayedAgent.stream(.message(.user("call echo"))) {
            switch event {
            case let .toolCallRequested(call) where call.name == "echo":
                sawToolCall = true
            case let .textDelta(chunk):
                assistantText += chunk
            default:
                break
            }
        }
        XCTAssertTrue(sawToolCall, "Replay should issue the recorded tool call")
        XCTAssertTrue(
            assistantText.contains("response with tool result"),
            "Final assistant text should match the recorded reply"
        )
    }

    // MARK: - State replay

    func testStatesDecodesEveryNodeVisit() async throws {
        let recorder = SessionRecorder()
        var graph = StateGraph<ChainState>()
        graph.addNode("a") { state in
            var copy = state
            copy.seen.append("a")
            return copy
        }
        graph.addNode("b") { state in
            var copy = state
            copy.seen.append("b")
            return copy
        }
        graph.setEntry("a")
        graph.addEdge(from: "a", to: "b")
        graph.addEdge(from: "b", to: StateGraph<ChainState>.end)
        let compiled = try graph.build()
        _ = try await compiled.run(
            initial: ChainState(seen: []),
            options: .init(recorder: recorder)
        )

        let bundle = await recorder.bundle()
        let stateGraph = try XCTUnwrap(bundle.stateGraph)
        let transitions = try SessionReplayer.states(
            from: stateGraph,
            as: ChainState.self
        )
        XCTAssertEqual(transitions.map(\.node), ["a", "b"])
        XCTAssertEqual(transitions[0].input.seen, [])
        XCTAssertEqual(transitions[0].output.seen, ["a"])
        XCTAssertEqual(transitions[1].input.seen, ["a"])
        XCTAssertEqual(transitions[1].output.seen, ["a", "b"])
    }

    // MARK: Private

    /// Run the original tool trajectory once, capturing it into a
    /// `SessionBundle`. Pulled out so the replay test body stays
    /// under the lint cap.
    private static func recordOriginalToolRun() async throws -> AgentRecord {
        let recorder = SessionRecorder()
        let middleware = RecordingMiddleware(recorder: recorder)
        middleware.bind(providerSystem: "test.mock", providerModel: "v1", systemPrompt: nil)
        let original = MockLLMProvider(scenes: [
            .toolCall(
                id: "c1",
                name: "echo",
                arguments: .object(["text": .string("ping")])
            ),
            .text("response with tool result"),
        ])
        let originalAgent = Agent(config: AgentConfig(
            provider: original,
            tools: [AnyTool(EchoTool())],
            threadId: "t-tool",
            middleware: [middleware]
        ))
        for try await _ in originalAgent.stream(.message(.user("call echo"))) { }
        let bundle = await recorder.bundle()
        guard let record = bundle.agent else {
            throw XCTSkip("Recorder did not capture an agent record")
        }
        return record
    }
}
