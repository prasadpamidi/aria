import Foundation
import Tracing

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
        edges: [String: Edge<State>],
        reducers: [AnyReducer<State>] = []
    ) {
        self.nodes = nodes
        self.edges = edges
        self.reducers = reducers
    }

    // MARK: Public

    // MARK: - RunOptions

    /// Per-run knobs.
    ///
    /// - `maxSteps` caps how many node transitions may occur before
    ///   execution aborts with `stepLimitExceeded`; a guardrail against
    ///   routing cycles, not a feature.
    /// - `checkpoint` opts in to per-node persistence via a
    ///   `Checkpointer`. When set, the run writes a checkpoint at the
    ///   end of each node so a future call to
    ///   `resume(threadId:checkpointer:options:)` can pick up after
    ///   the last completed node.
    public struct RunOptions: Sendable {
        // MARK: Lifecycle

        public init(
            maxSteps: Int = 256,
            checkpoint: CheckpointConfig? = nil
        ) {
            precondition(maxSteps > 0, "maxSteps must be > 0")
            self.maxSteps = maxSteps
            self.checkpoint = checkpoint
        }

        // MARK: Public

        public let maxSteps: Int
        public let checkpoint: CheckpointConfig?
    }

    // MARK: - CheckpointConfig

    /// Pairs a `Checkpointer` with the thread id under which graph
    /// runs are recorded. The graph stores one checkpoint per
    /// `nodeEnd`, with the completed node's name in `metadata` so
    /// `resume(threadId:checkpointer:options:)` can pick the next
    /// edge.
    public struct CheckpointConfig: Sendable {
        // MARK: Lifecycle

        public init(checkpointer: any Checkpointer, threadId: String) {
            self.checkpointer = checkpointer
            self.threadId = threadId
        }

        // MARK: Public

        public let checkpointer: any Checkpointer
        public let threadId: String
    }

    /// Stream the graph's events for the given initial state. The
    /// stream finishes once execution reaches `StateGraph.end`.
    public func stream(
        initial: State,
        options: RunOptions = RunOptions()
    ) -> AsyncThrowingStream<StateGraphEvent<State>, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await withSpan(AriaSemConv.Span.stateGraphRun, ofKind: .internal) { span in
                    span.attributes[AriaSemConv.Aria.stateGraphReducerCount] =
                        Int64(self.reducers.count)
                    await self.runHandlingErrors(
                        initial: initial,
                        options: options,
                        continuation: continuation
                    )
                }
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

    /// Resume a previously-checkpointed run.
    ///
    /// Looks up the latest checkpoint for `threadId`, decodes the
    /// stored `State`, and restarts execution from the edge leaving
    /// the last completed node. New checkpoints continue to land in
    /// the same thread, so subsequent `resume` calls keep advancing.
    ///
    /// Throws `StateGraphError.invalidGraph` if the thread has no
    /// checkpoint or the checkpoint references a node the compiled
    /// graph no longer recognizes.
    public func resume(
        threadId: String,
        checkpointer: any Checkpointer,
        options: RunOptions = RunOptions()
    ) -> AsyncThrowingStream<StateGraphEvent<State>, any Error> {
        let resumeOptions = RunOptions(
            maxSteps: options.maxSteps,
            checkpoint: CheckpointConfig(
                checkpointer: checkpointer,
                threadId: threadId
            )
        )
        return AsyncThrowingStream { continuation in
            let task = Task {
                await withSpan(AriaSemConv.Span.stateGraphResume, ofKind: .internal) { span in
                    span.attributes[AriaSemConv.Aria.threadId] = threadId
                    await self.resumeHandlingErrors(
                        threadId: threadId,
                        checkpointer: checkpointer,
                        options: resumeOptions,
                        continuation: continuation
                    )
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Internal

    // Read by `CompiledStateGraph+Parallel.swift` — extensions in
    // different files can't see `private`, so these are internal.
    let nodes: [String: Node<State>]
    let edges: [String: Edge<State>]
    let reducers: [AnyReducer<State>]

    /// Resolve a non-fan-out edge to a single next-node name. Parallel
    /// edges are routed through `runParallel` directly because they
    /// produce a merged state in addition to a next node. Internal so
    /// the parallel-helpers extension can call it.
    static func resolve(
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
        case .parallel:
            throw StateGraphError.invalidGraph(
                "Parallel edges must be handled by runParallel; resolve called on .parallel"
            )
        }
    }

    static func writeCheckpoint(
        state: State,
        completedNode: String,
        config: CheckpointConfig
    ) async throws {
        let data = try JSONEncoder().encode(state)
        let checkpoint = Checkpoint(
            threadId: config.threadId,
            state: data,
            metadata: [Self.completedNodeKey: .string(completedNode)]
        )
        try await config.checkpointer.put(checkpoint, threadId: config.threadId)
    }

    // MARK: Private

    /// Metadata key used to record which node produced a checkpoint.
    /// Read on `resume` to find the edge that should fire next.
    private static var completedNodeKey: String {
        "stateGraph.completedNode"
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
        // build() guarantees an entry edge exists; the guard keeps the
        // contract enforceable at runtime if the invariant is ever
        // violated by future edits.
        guard let entryEdge = self.edges[StateGraph<State>.start] else {
            throw StateGraphError.invalidGraph("Compiled graph is missing its entry edge")
        }
        let firstNode = try Self.resolve(entryEdge, state: initial)
        try await self.runFromNode(
            startNode: firstNode,
            initialState: initial,
            options: options,
            continuation: continuation
        )
    }

    private func resumeHandlingErrors(
        threadId: String,
        checkpointer: any Checkpointer,
        options: RunOptions,
        continuation: AsyncThrowingStream<StateGraphEvent<State>, any Error>.Continuation
    ) async {
        do {
            try await self.runResume(
                threadId: threadId,
                checkpointer: checkpointer,
                options: options,
                continuation: continuation
            )
        } catch is CancellationError {
            continuation.finish(throwing: CancellationError())
        } catch {
            continuation.finish(throwing: error)
        }
    }

    private func runResume(
        threadId: String,
        checkpointer: any Checkpointer,
        options: RunOptions,
        continuation: AsyncThrowingStream<StateGraphEvent<State>, any Error>.Continuation
    ) async throws {
        guard let checkpoint = try await checkpointer.latest(threadId: threadId) else {
            throw StateGraphError.invalidGraph(
                "No checkpoint found for thread '\(threadId)'"
            )
        }
        guard case let .string(completedNode) = checkpoint.metadata[Self.completedNodeKey] else {
            throw StateGraphError.invalidGraph(
                "Checkpoint for thread '\(threadId)' has no completedNode metadata"
            )
        }
        let state = try JSONDecoder().decode(State.self, from: checkpoint.state)
        guard let edgeFromCompleted = self.edges[completedNode] else {
            throw StateGraphError.noEdgeFromNode(completedNode)
        }
        let nextNode = try Self.resolve(edgeFromCompleted, state: state)
        if nextNode == StateGraph<State>.end {
            continuation.yield(.finish(state: state))
            continuation.finish()
            return
        }
        try await self.runFromNode(
            startNode: nextNode,
            initialState: state,
            options: options,
            continuation: continuation
        )
    }

    // `runFromNode` and the parallel + reducer-fold helpers live in
    // `CompiledStateGraph+Parallel.swift` to keep this type body
    // under SwiftLint's body-length limit.
}
