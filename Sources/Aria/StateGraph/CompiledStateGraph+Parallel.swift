import Foundation
import Tracing

// MARK: - CompiledStateGraph + parallel/reducer helpers

extension CompiledStateGraph {
    /// Drives node execution from `startNode`. Shared between fresh
    /// runs (called with the entry edge's target) and resumes
    /// (called with the edge target after the last completed node).
    func runFromNode(
        startNode: String,
        initialState: State,
        options: RunOptions,
        continuation: AsyncThrowingStream<StateGraphEvent<State>, any Error>.Continuation
    ) async throws {
        var state = initialState
        var nextName = startNode
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
            state = try await self.runNode(node, state: state, continuation: continuation)
            try await self.writeCheckpointIfEnabled(
                state: state, node: node.name, options: options
            )
            (state, nextName) = try await self.advance(
                from: node.name, state: state, options: options, continuation: continuation
            )
        }
        continuation.yield(.finish(state: state))
        continuation.finish()
    }

    /// Resolve the next node from the edge leaving `name`. For
    /// parallel edges, fan out + merge inline and return the joinAt
    /// target along with the merged state.
    private func advance(
        from name: String,
        state: State,
        options: RunOptions,
        continuation: AsyncThrowingStream<StateGraphEvent<State>, any Error>.Continuation
    ) async throws -> (State, String) {
        guard let edge = self.edges[name] else {
            throw StateGraphError.noEdgeFromNode(name)
        }
        switch edge {
        case .static, .conditional:
            return try (state, Self.resolve(edge, state: state))
        case let .parallel(branches, joinAt):
            let merged = try await self.runParallel(
                branches: branches, input: state, continuation: continuation
            )
            try await self.writeCheckpointIfEnabled(
                state: merged, node: name, options: options
            )
            return (merged, joinAt)
        }
    }

    private func writeCheckpointIfEnabled(
        state: State,
        node: String,
        options: RunOptions
    ) async throws {
        if let config = options.checkpoint {
            try await Self.writeCheckpoint(
                state: state, completedNode: node, config: config
            )
        }
    }

    /// Run a single node: emit `.nodeStart`, await `node.run`, emit
    /// `.nodeEnd`. Used by both the linear path and parallel branches.
    func runNode(
        _ node: Node<State>,
        state: State,
        continuation: AsyncThrowingStream<StateGraphEvent<State>, any Error>.Continuation
    ) async throws -> State {
        try await withSpan(AriaSemConv.Span.stateGraphNode, ofKind: .internal) { span in
            span.attributes[AriaSemConv.Aria.stateGraphNode] = node.name
            AriaMetrics.stateGraphNodeExecutions(name: node.name).increment()
            continuation.yield(.nodeStart(name: node.name, state: state))
            let nextState = try await node.run(state)
            continuation.yield(.nodeEnd(name: node.name, state: nextState))
            return nextState
        }
    }

    /// Fan-out execution: run each branch node concurrently with the
    /// same input state, then fold their outputs through any
    /// registered reducers. The merged state is the return value;
    /// `nodeStart` / `nodeEnd` events are yielded as branches start
    /// and finish.
    func runParallel(
        branches: [String],
        input: State,
        continuation: AsyncThrowingStream<StateGraphEvent<State>, any Error>.Continuation
    ) async throws -> State {
        try await withSpan(AriaSemConv.Span.stateGraphParallel, ofKind: .internal) { span in
            span.attributes[AriaSemConv.Aria.stateGraphParallelBranches] = branches
            let outputs = try await self.runBranchesInParallel(
                branches: branches,
                input: input,
                continuation: continuation
            )
            return self.foldOutputs(outputs, input: input)
        }
    }

    // MARK: Private

    /// Drive each branch concurrently in a `TaskGroup`. Branch tasks
    /// return `(declarationIndex, output)` so the caller can fold
    /// them in declared order regardless of completion order.
    private func runBranchesInParallel(
        branches: [String],
        input: State,
        continuation: AsyncThrowingStream<StateGraphEvent<State>, any Error>.Continuation
    ) async throws -> [State] {
        try await withThrowingTaskGroup(
            of: (Int, State).self,
            returning: [State].self
        ) { group in
            for (index, branchName) in branches.enumerated() {
                guard let node = self.nodes[branchName] else {
                    throw StateGraphError.invalidGraph(
                        "Parallel branch references unknown node '\(branchName)'"
                    )
                }
                group.addTask {
                    let result = try await self.runNode(
                        node, state: input, continuation: continuation
                    )
                    return (index, result)
                }
            }
            var collected: [(Int, State)] = []
            for try await pair in group {
                collected.append(pair)
            }
            collected.sort(by: { $0.0 < $1.0 })
            return collected.map(\.1)
        }
    }

    /// Fold branch outputs through registered reducers. Starts from
    /// the parallel section's input state, then for each output:
    /// runs every reducer (each reducer reads its field from the
    /// accumulator and the new output, writes the merged value back).
    /// Fields without a reducer end up with the last branch's value
    /// (declaration-order last-write-wins).
    private func foldOutputs(
        _ outputs: [State],
        input: State
    ) -> State {
        var merged = input
        for branchOutput in outputs {
            var next = branchOutput
            for reducer in self.reducers {
                reducer.apply(merged, &next)
            }
            merged = next
        }
        return merged
    }
}
