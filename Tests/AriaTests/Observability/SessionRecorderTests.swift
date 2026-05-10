import Foundation
import XCTest
@testable import Aria
@testable import AriaTesting

// MARK: - ChainState

private struct ChainState: Codable, Equatable {
    var seen: [String]
}

// MARK: - SessionRecorderTests

final class SessionRecorderTests: XCTestCase {
    // MARK: - Agent capture

    func testRecordingMiddlewareCapturesAgentRun() async throws {
        let recorder = SessionRecorder()
        let middleware = RecordingMiddleware(recorder: recorder)
        middleware.bind(
            providerSystem: "test.mock",
            providerModel: "mock.v1",
            systemPrompt: "be brief"
        )
        let provider = MockLLMProvider(scenes: [.text("hi there")])
        let agent = Agent(config: AgentConfig(
            provider: provider,
            tools: [],
            systemPrompt: "be brief",
            threadId: "t-record",
            middleware: [middleware]
        ))

        for try await _ in agent.stream(.message(.user("hello"))) { }

        let bundle = await recorder.bundle()
        let agentRecord = try XCTUnwrap(bundle.agent, "Expected agent record")
        XCTAssertEqual(agentRecord.threadId, "t-record")
        XCTAssertEqual(agentRecord.providerSystem, "test.mock")
        XCTAssertEqual(agentRecord.providerModel, "mock.v1")
        XCTAssertEqual(agentRecord.systemPrompt, "be brief")
        XCTAssertEqual(agentRecord.steps.count, 1, "Expected one step")
        XCTAssertEqual(agentRecord.steps.first?.index, 0)
        XCTAssertTrue(
            agentRecord.finalMessages.last?.textContent.contains("hi there") ?? false,
            "Final message log should contain assistant reply"
        )
    }

    // MARK: - StateGraph capture

    func testRunOptionsRecorderCapturesStateGraphNodes() async throws {
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
        let stateGraph = try XCTUnwrap(bundle.stateGraph, "Expected stateGraph record")
        XCTAssertEqual(stateGraph.nodes.map(\.name), ["a", "b"])
        // Decode the captured state payloads back to ChainState and
        // confirm they reflect the actual transitions.
        let decoder = JSONDecoder()
        let aIn = try decoder.decode(ChainState.self, from: stateGraph.nodes[0].inputState)
        let aOut = try decoder.decode(ChainState.self, from: stateGraph.nodes[0].outputState)
        let bIn = try decoder.decode(ChainState.self, from: stateGraph.nodes[1].inputState)
        let bOut = try decoder.decode(ChainState.self, from: stateGraph.nodes[1].outputState)
        XCTAssertEqual(aIn.seen, [])
        XCTAssertEqual(aOut.seen, ["a"])
        XCTAssertEqual(bIn.seen, ["a"])
        XCTAssertEqual(bOut.seen, ["a", "b"])
    }

    // MARK: - Bundle round-trip

    func testBundleEncodesAndDecodesAsJSON() async throws {
        let recorder = SessionRecorder()
        var graph = StateGraph<ChainState>()
        graph.addNode("only") { state in
            var copy = state
            copy.seen.append("only")
            return copy
        }
        graph.setEntry("only")
        graph.addEdge(from: "only", to: StateGraph<ChainState>.end)
        let compiled = try graph.build()
        _ = try await compiled.run(
            initial: ChainState(seen: []),
            options: .init(recorder: recorder)
        )

        let bundle = await recorder.bundle()
        let data = try JSONEncoder().encode(bundle)
        let decoded = try JSONDecoder().decode(SessionBundle.self, from: data)
        XCTAssertEqual(decoded, bundle)
    }
}
