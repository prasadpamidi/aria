import XCTest
@testable import Aria

// MARK: - CounterState

private struct CounterState: Codable, Equatable {
    var value: Int
    var trail: [String]
}

// MARK: - StateGraphTests

final class StateGraphTests: XCTestCase {
    // MARK: - Build-time validation

    func testBuildFailsWhenEntryEdgeMissing() {
        var graph = StateGraph<CounterState>()
        graph.addNode("inc") { state in
            var copy = state
            copy.value += 1
            return copy
        }
        graph.addEdge(from: "inc", to: StateGraph<CounterState>.end)
        XCTAssertThrowsError(try graph.build()) { error in
            guard case .invalidGraph = error as? StateGraphError else {
                XCTFail("Expected invalidGraph, got \(error)")
                return
            }
        }
    }

    func testBuildFailsWhenEdgeReferencesUnknownNode() {
        var graph = StateGraph<CounterState>()
        graph.addNode("inc") { state in state }
        graph.setEntry("inc")
        graph.addEdge(from: "inc", to: "ghost")
        XCTAssertThrowsError(try graph.build())
    }

    func testBuildFailsWhenNodeHasNoOutgoingEdge() {
        var graph = StateGraph<CounterState>()
        graph.addNode("inc") { state in state }
        graph.addNode("end") { state in state }
        graph.setEntry("inc")
        graph.addEdge(from: "inc", to: "end")
        // 'end' is a node, not the sentinel, so it needs an outgoing
        // edge of its own.
        XCTAssertThrowsError(try graph.build())
    }

    // MARK: - Linear execution

    func testLinearGraphRunsNodesInOrder() async throws {
        var graph = StateGraph<CounterState>()
        graph.addNode("a") { state in
            var copy = state
            copy.value += 1
            copy.trail.append("a")
            return copy
        }
        graph.addNode("b") { state in
            var copy = state
            copy.value *= 2
            copy.trail.append("b")
            return copy
        }
        graph.setEntry("a")
        graph.addEdge(from: "a", to: "b")
        graph.addEdge(from: "b", to: StateGraph<CounterState>.end)
        let compiled = try graph.build()

        let initial = CounterState(value: 3, trail: [])
        let final = try await compiled.run(initial: initial)
        XCTAssertEqual(final.value, (3 + 1) * 2)
        XCTAssertEqual(final.trail, ["a", "b"])
    }

    func testStreamYieldsNodeStartAndEndEvents() async throws {
        var graph = StateGraph<CounterState>()
        graph.addNode("a") { state in
            var copy = state
            copy.trail.append("a")
            return copy
        }
        graph.setEntry("a")
        graph.addEdge(from: "a", to: StateGraph<CounterState>.end)
        let compiled = try graph.build()

        var events: [String] = []
        for try await event in compiled.stream(initial: CounterState(value: 0, trail: [])) {
            switch event {
            case let .nodeStart(name, _): events.append("start:\(name)")
            case let .nodeEnd(name, _): events.append("end:\(name)")
            case .finish: events.append("finish")
            }
        }
        XCTAssertEqual(events, ["start:a", "end:a", "finish"])
    }

    // MARK: - Conditional routing

    func testConditionalEdgeRoutesByState() async throws {
        var graph = StateGraph<CounterState>()
        graph.addNode("classify") { state in state }
        graph.addNode("positive") { state in
            var copy = state
            copy.trail.append("+")
            return copy
        }
        graph.addNode("negative") { state in
            var copy = state
            copy.trail.append("-")
            return copy
        }
        graph.setEntry("classify")
        graph.addConditionalEdge(
            from: "classify",
            targets: ["positive", "negative"]
        ) { state in
            state.value >= 0 ? "positive" : "negative"
        }
        graph.addEdge(from: "positive", to: StateGraph<CounterState>.end)
        graph.addEdge(from: "negative", to: StateGraph<CounterState>.end)
        let compiled = try graph.build()

        let positiveResult = try await compiled.run(initial: CounterState(value: 5, trail: []))
        XCTAssertEqual(positiveResult.trail, ["+"])
        let negativeResult = try await compiled.run(initial: CounterState(value: -1, trail: []))
        XCTAssertEqual(negativeResult.trail, ["-"])
    }

    func testConditionalEdgeRejectsUnknownTarget() async throws {
        var graph = StateGraph<CounterState>()
        graph.addNode("a") { state in state }
        graph.addNode("b") { state in state }
        graph.setEntry("a")
        graph.addConditionalEdge(
            from: "a",
            targets: ["b"]
        ) { _ in "ghost" } // routing function lies about a target
        graph.addEdge(from: "b", to: StateGraph<CounterState>.end)
        let compiled = try graph.build()

        do {
            _ = try await compiled.run(initial: CounterState(value: 0, trail: []))
            XCTFail("Expected invalidRoute")
        } catch let error as StateGraphError {
            guard case let .invalidRoute(_, returned, _) = error else {
                XCTFail("Expected invalidRoute, got \(error)")
                return
            }
            XCTAssertEqual(returned, "ghost")
        }
    }

    // MARK: - Cycle protection

    func testStepLimitTrips() async throws {
        var graph = StateGraph<CounterState>()
        graph.addNode("loop") { state in
            var copy = state
            copy.value += 1
            return copy
        }
        graph.setEntry("loop")
        graph.addEdge(from: "loop", to: "loop") // intentional cycle
        let compiled = try graph.build()

        do {
            _ = try await compiled.run(
                initial: CounterState(value: 0, trail: []),
                options: .init(maxSteps: 5)
            )
            XCTFail("Expected stepLimitExceeded")
        } catch let error as StateGraphError {
            guard case let .stepLimitExceeded(limit) = error else {
                XCTFail("Expected stepLimitExceeded, got \(error)")
                return
            }
            XCTAssertEqual(limit, 5)
        }
    }
}
