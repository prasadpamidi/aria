import Foundation

// MARK: - CompiledStateGraph

/// A validated, runnable graph produced by `StateGraph.build()`.
///
/// `stream(initial:options:)` returns an async sequence of
/// `StateGraphEvent`s; `run(initial:options:)` collapses the stream to
/// the final state for callers that don't need to observe per-node
/// transitions. Both honor `Task` cancellation.
public struct CompiledStateGraph<State: Sendable & Codable>: Sendable {
    // MARK: Lifecycle

    init(
        nodes: [String: Node<State>],
        edges: [String: Edge<State>]
    ) {
        self.nodes = nodes
        self.edges = edges
    }

    // MARK: Public

    // MARK: - RunOptions

    /// Per-run knobs. `maxSteps` caps how many node transitions may
    /// occur before execution aborts with `stepLimitExceeded`; the
    /// limit is a guardrail against routing cycles, not a feature.
    public struct RunOptions: Sendable {
        // MARK: Lifecycle

        public init(maxSteps: Int = 256) {
            precondition(maxSteps > 0, "maxSteps must be > 0")
            self.maxSteps = maxSteps
        }

        // MARK: Public

        public let maxSteps: Int
    }

    /// Stream the graph's events for the given initial state. The
    /// stream finishes once execution reaches `StateGraph.end`.
    public func stream(
        initial: State,
        options: RunOptions = RunOptions()
    ) -> AsyncThrowingStream<StateGraphEvent<State>, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.runHandlingErrors(
                    initial: initial,
                    options: options,
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Run the graph and return only the final state. Useful when the
    /// caller doesn't need per-node observability.
    public func run(
        initial: State,
        options: RunOptions = RunOptions()
    ) async throws -> State {
        var current = initial
        for try await event in self.stream(initial: initial, options: options) {
            if case let .finish(state) = event {
                current = state
            }
        }
        return current
    }

    // MARK: Private

    private let nodes: [String: Node<State>]
    private let edges: [String: Edge<State>]

    private static func resolve(
        _ edge: Edge<State>,
        state: State
    ) throws -> String {
        switch edge {
        case let .static(target):
            return target
        case let .conditional(targets, route):
            let chosen = route(state)
            guard targets.contains(chosen) || chosen == StateGraph<State>.end else {
                throw StateGraphError.invalidRoute(
                    from: "?",
                    returned: chosen,
                    allowed: targets
                )
            }
            return chosen
        }
    }

    private func runHandlingErrors(
        initial: State,
        options: RunOptions,
        continuation: AsyncThrowingStream<StateGraphEvent<State>, any Error>.Continuation
    ) async {
        do {
            try await self.run(
                initial: initial,
                options: options,
                continuation: continuation
            )
        } catch is CancellationError {
            continuation.finish(throwing: CancellationError())
        } catch {
            continuation.finish(throwing: error)
        }
    }

    private func run(
        initial: State,
        options: RunOptions,
        continuation: AsyncThrowingStream<StateGraphEvent<State>, any Error>.Continuation
    ) async throws {
        var state = initial
        // build() guarantees an entry edge exists; the guard keeps the
        // contract enforceable at runtime if the invariant is ever
        // violated by future edits.
        guard let entryEdge = self.edges[StateGraph<State>.start] else {
            throw StateGraphError.invalidGraph("Compiled graph is missing its entry edge")
        }
        var nextName = try Self.resolve(entryEdge, state: state)
        var stepCount = 0

        while nextName != StateGraph<State>.end {
            try Task.checkCancellation()
            stepCount += 1
            if stepCount > options.maxSteps {
                throw StateGraphError.stepLimitExceeded(limit: options.maxSteps)
            }

            guard let node = self.nodes[nextName] else {
                throw StateGraphError.invalidGraph(
                    "Routing produced unknown node '\(nextName)'"
                )
            }

            continuation.yield(.nodeStart(name: node.name, state: state))
            state = try await node.run(state)
            continuation.yield(.nodeEnd(name: node.name, state: state))

            guard let edge = self.edges[node.name] else {
                throw StateGraphError.noEdgeFromNode(node.name)
            }
            nextName = try Self.resolve(edge, state: state)
        }

        continuation.yield(.finish(state: state))
        continuation.finish()
    }
}
