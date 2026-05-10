import XCTest
@testable import Aria

// MARK: - FanOutState

private struct FanOutState: Codable, Equatable {
    var greetings: [String]
    var votes: Int
    var winner: String
}

// MARK: - StateGraphParallelTests

final class StateGraphParallelTests: XCTestCase {
    // MARK: - Reducers

    func testParallelMergesViaRegisteredReducers() async throws {
        var graph = StateGraph<FanOutState>()
        graph.addNode("seed") { state in state }
        graph.addNode("hello") { state in
            var copy = state
            copy.greetings.append("hello")
            copy.votes += 1
            return copy
        }
        graph.addNode("hi") { state in
            var copy = state
            copy.greetings.append("hi")
            copy.votes += 1
            return copy
        }
        graph.addNode("hey") { state in
            var copy = state
            copy.greetings.append("hey")
            copy.votes += 1
            return copy
        }
        graph.addNode("collect") { state in state }

        graph.setEntry("seed")
        graph.addParallelEdge(
            from: "seed",
            branches: ["hello", "hi", "hey"],
            joinAt: "collect"
        )
        graph.addEdge(from: "collect", to: StateGraph<FanOutState>.end)

        // Default last-write-wins on `winner` (no reducer); reducers
        // accumulate `greetings` and sum `votes`.
        graph.addReducer(for: \FanOutState.greetings) { existing, new in existing + new }
        graph.addReducer(for: \FanOutState.votes) { existing, new in existing + new }

        let compiled = try graph.build()
        let final = try await compiled.run(
            initial: FanOutState(greetings: [], votes: 0, winner: "")
        )
        XCTAssertEqual(Set(final.greetings), Set(["hello", "hi", "hey"]))
        XCTAssertEqual(final.greetings.count, 3, "Reducer should preserve all branch contributions")
        XCTAssertEqual(final.votes, 3, "Sum reducer should aggregate votes across branches")
    }

    func testParallelLastWriteWinsWithoutReducer() async throws {
        var graph = StateGraph<FanOutState>()
        graph.addNode("seed") { state in state }
        graph.addNode("first") { state in
            var copy = state
            copy.winner = "first"
            return copy
        }
        graph.addNode("second") { state in
            var copy = state
            copy.winner = "second"
            return copy
        }
        graph.addNode("collect") { state in state }

        graph.setEntry("seed")
        graph.addParallelEdge(
            from: "seed",
            branches: ["first", "second"],
            joinAt: "collect"
        )
        graph.addEdge(from: "collect", to: StateGraph<FanOutState>.end)

        let compiled = try graph.build()
        let final = try await compiled.run(
            initial: FanOutState(greetings: [], votes: 0, winner: "")
        )
        // Branches are folded in declaration order; "second" comes last.
        XCTAssertEqual(final.winner, "second")
    }

    // MARK: - Validation

    func testBuildFailsWhenParallelBranchUnknown() {
        var graph = StateGraph<FanOutState>()
        graph.addNode("seed") { state in state }
        graph.addNode("collect") { state in state }
        graph.setEntry("seed")
        graph.addParallelEdge(
            from: "seed",
            branches: ["ghost"], // not registered
            joinAt: "collect"
        )
        graph.addEdge(from: "collect", to: StateGraph<FanOutState>.end)
        XCTAssertThrowsError(try graph.build()) { error in
            guard case .invalidGraph = error as? StateGraphError else {
                XCTFail("Expected invalidGraph, got \(error)")
                return
            }
        }
    }

    func testBuildFailsWhenParallelJoinUnknown() {
        var graph = StateGraph<FanOutState>()
        graph.addNode("seed") { state in state }
        graph.addNode("a") { state in state }
        graph.addEdge(from: "a", to: StateGraph<FanOutState>.end)
        graph.setEntry("seed")
        graph.addParallelEdge(
            from: "seed",
            branches: ["a"],
            joinAt: "ghost"
        )
        XCTAssertThrowsError(try graph.build())
    }

    // MARK: - Streaming

    func testParallelEmitsNodeEventsForEachBranch() async throws {
        var graph = StateGraph<FanOutState>()
        graph.addNode("seed") { state in state }
        graph.addNode("a") { state in state }
        graph.addNode("b") { state in state }
        graph.addNode("collect") { state in state }
        graph.setEntry("seed")
        graph.addParallelEdge(
            from: "seed",
            branches: ["a", "b"],
            joinAt: "collect"
        )
        graph.addEdge(from: "collect", to: StateGraph<FanOutState>.end)

        let compiled = try graph.build()
        var nodeStarts: Set<String> = []
        var nodeEnds: Set<String> = []
        var sawFinish = false
        for try await event in compiled.stream(
            initial: FanOutState(greetings: [], votes: 0, winner: "")
        ) {
            switch event {
            case let .nodeStart(name, _): nodeStarts.insert(name)
            case let .nodeEnd(name, _): nodeEnds.insert(name)
            case .finish: sawFinish = true
            }
        }
        XCTAssertEqual(nodeStarts, Set(["seed", "a", "b", "collect"]))
        XCTAssertEqual(nodeEnds, Set(["seed", "a", "b", "collect"]))
        XCTAssertTrue(sawFinish)
    }
}
