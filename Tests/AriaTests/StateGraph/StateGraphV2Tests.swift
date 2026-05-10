import XCTest
@testable import Aria
@testable import AriaTesting

// MARK: - TwoStepState

private struct TwoStepState: Codable, Equatable {
    var first: String?
    var second: String?
}

// MARK: - StateGraphV2Tests

final class StateGraphV2Tests: XCTestCase {
    // MARK: Internal

    // MARK: - Agent-as-node

    func testAddAgentNodeRunsAgentAndWritesResult() async throws {
        let provider = MockLLMProvider(scenes: [.text("hello world")])
        let agent = Agent(config: AgentConfig(
            provider: provider,
            tools: [],
            threadId: "t"
        ))

        var graph = StateGraph<TwoStepState>()
        graph.addAgentNode(
            "say",
            agent: agent,
            prompt: { _ in "hi" },
            writeResult: { state, text in state.first = text }
        )
        graph.setEntry("say")
        graph.addEdge(from: "say", to: StateGraph<TwoStepState>.end)
        let compiled = try graph.build()

        let final = try await compiled.run(initial: TwoStepState())
        XCTAssertEqual(final.first, "hello world")
    }

    // MARK: - Checkpointer integration

    func testCheckpointWritesAfterEachNodeEnd() async throws {
        let checkpointer = InMemoryCheckpointer()
        let threadId = "t-write"

        var graph = StateGraph<TwoStepState>()
        graph.addNode("a") { state in
            var copy = state
            copy.first = "first"
            return copy
        }
        graph.addNode("b") { state in
            var copy = state
            copy.second = "second"
            return copy
        }
        graph.setEntry("a")
        graph.addEdge(from: "a", to: "b")
        graph.addEdge(from: "b", to: StateGraph<TwoStepState>.end)
        let compiled = try graph.build()

        _ = try await compiled.run(
            initial: TwoStepState(),
            options: .init(checkpoint: .init(checkpointer: checkpointer, threadId: threadId))
        )

        let checkpoints = try await checkpointer.list(threadId: threadId, limit: 10)
        XCTAssertEqual(checkpoints.count, 2, "Two nodeEnd events → two checkpoints")
        // Latest first.
        guard case let .string(latestNode) = checkpoints[0].metadata["stateGraph.completedNode"] else {
            XCTFail("Latest checkpoint missing completedNode metadata")
            return
        }
        XCTAssertEqual(latestNode, "b")
    }

    func testResumeStartsFromEdgeAfterLastCompletedNode() async throws {
        let checkpointer = InMemoryCheckpointer()
        let threadId = "t-resume"
        // Stage 1: drop a checkpoint at node 'b' via a 2-node prefix.
        try await Self.runPrefix(checkpointer: checkpointer, threadId: threadId)

        // Stage 2: resume on a graph that adds 'c' after 'b'.
        let compiledFull = try Self.makeFullGraph()
        var resumedNodes: [String] = []
        var finalState: TwoStepState?
        for try await event in compiledFull.resume(threadId: threadId, checkpointer: checkpointer) {
            switch event {
            case let .nodeStart(name, _): resumedNodes.append(name)
            case let .finish(state): finalState = state
            default: break
            }
        }
        XCTAssertEqual(resumedNodes, ["c"], "Resume should skip the already-completed prefix")
        XCTAssertEqual(finalState?.first, "from-a | c", "State should carry forward from the checkpoint")
        XCTAssertEqual(finalState?.second, "from-b")
    }

    func testResumeWithoutCheckpointThrows() async {
        var graph = StateGraph<TwoStepState>()
        graph.addNode("a") { state in state }
        graph.setEntry("a")
        graph.addEdge(from: "a", to: StateGraph<TwoStepState>.end)
        let compiled = try? graph.build()
        guard let compiled else {
            XCTFail("Build failed")
            return
        }

        let checkpointer = InMemoryCheckpointer()
        do {
            for try await _ in compiled.resume(threadId: "missing", checkpointer: checkpointer) { }
            XCTFail("Expected invalidGraph for missing checkpoint")
        } catch let error as StateGraphError {
            guard case .invalidGraph = error else {
                XCTFail("Expected invalidGraph, got \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testResumeAfterTerminalNodeYieldsFinishOnly() async throws {
        let checkpointer = InMemoryCheckpointer()
        let threadId = "t-terminal"

        // Run a graph end-to-end with checkpointing.
        var graph = StateGraph<TwoStepState>()
        graph.addNode("a") { state in
            var copy = state
            copy.first = "done"
            return copy
        }
        graph.setEntry("a")
        graph.addEdge(from: "a", to: StateGraph<TwoStepState>.end)
        let compiled = try graph.build()
        _ = try await compiled.run(
            initial: TwoStepState(),
            options: .init(checkpoint: .init(checkpointer: checkpointer, threadId: threadId))
        )

        // Resume. Last completed node is 'a' which routes straight to
        // .end → resume should immediately yield .finish, not run 'a' again.
        var startedNodes: [String] = []
        var finished = false
        for try await event in compiled.resume(threadId: threadId, checkpointer: checkpointer) {
            switch event {
            case let .nodeStart(name, _): startedNodes.append(name)
            case .finish: finished = true
            default: break
            }
        }
        XCTAssertTrue(startedNodes.isEmpty, "No nodes should run on a fully-completed resume")
        XCTAssertTrue(finished)
    }

    // MARK: Private

    private static func runPrefix(
        checkpointer: any Checkpointer, threadId: String
    ) async throws {
        var prefix = StateGraph<TwoStepState>()
        prefix.addNode("a") { state in
            var copy = state
            copy.first = "from-a"
            return copy
        }
        prefix.addNode("b") { state in
            var copy = state
            copy.second = "from-b"
            return copy
        }
        prefix.setEntry("a")
        prefix.addEdge(from: "a", to: "b")
        prefix.addEdge(from: "b", to: StateGraph<TwoStepState>.end)
        _ = try await prefix.build().run(
            initial: TwoStepState(),
            options: .init(checkpoint: .init(checkpointer: checkpointer, threadId: threadId))
        )
    }

    private static func makeFullGraph() throws -> CompiledStateGraph<TwoStepState> {
        var full = StateGraph<TwoStepState>()
        full.addNode("a") { _ in TwoStepState() } // not exercised on resume
        full.addNode("b") { _ in TwoStepState() } // not exercised on resume
        full.addNode("c") { state in
            var copy = state
            copy.first = state.first.map { $0 + " | c" } ?? "c-only"
            return copy
        }
        full.setEntry("a")
        full.addEdge(from: "a", to: "b")
        full.addEdge(from: "b", to: "c")
        full.addEdge(from: "c", to: StateGraph<TwoStepState>.end)
        return try full.build()
    }
}
