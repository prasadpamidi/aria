import Foundation

// MARK: - StateGraph

/// A directed graph of named nodes that operate on a typed `State`
/// value. Nodes execute sequentially: each one receives the current
/// state and returns a new state, then control passes along whichever
/// edge applies until a node leads to `StateGraph.end`.
///
/// Build with `addNode` / `addEdge` / `addConditionalEdge` /
/// `addParallelEdge` / `addReducer` / `setEntry`, then call `build()`
/// to validate the graph and produce a `CompiledStateGraph` that can
/// stream events.
///
/// Reducers + parallel edges work together: a parallel edge fans the
/// current state out to N branch nodes that run concurrently, and
/// reducers describe how to merge each branch's `State` back into
/// one. Without a registered reducer for a field, last-write-wins.
public struct StateGraph<State: Sendable & Codable>: Sendable {
    // MARK: Lifecycle

    public init() { }

    // MARK: Public

    /// Sentinel name for the implicit start of the graph. Pass this as
    /// `from:` to wire the entry edge, or rely on `setEntry(_:)`.
    public static var start: String {
        "__start__"
    }

    /// Sentinel name for the implicit end of the graph. An edge whose
    /// target is `end` halts execution and yields the final state.
    public static var end: String {
        "__end__"
    }

    /// Register a node that transforms the state.
    public mutating func addNode(
        _ name: String,
        _ run: @Sendable @escaping (State) async throws -> State
    ) {
        precondition(
            name != Self.start && name != Self.end,
            "Cannot register a node named with a reserved sentinel"
        )
        self.nodes[name] = Node(name: name, run: run)
    }

    /// Add a static edge from one node to another. Use `Self.start` for
    /// the entry edge (or call `setEntry(_:)`) and `Self.end` to mark a
    /// terminal transition.
    public mutating func addEdge(from source: String, to target: String) {
        self.edges[source] = .static(target)
    }

    /// Add a conditional edge that picks the next node by inspecting
    /// the current state. `targets` declares the set of valid
    /// destinations the router may return — used at `build()` time to
    /// validate references and at run time to detect routing bugs.
    public mutating func addConditionalEdge(
        from source: String,
        targets: [String],
        _ route: @Sendable @escaping (State) -> String
    ) {
        precondition(!targets.isEmpty, "Conditional edge must declare at least one target")
        self.edges[source] = .conditional(
            targets: Set(targets),
            route: route
        )
    }

    /// Convenience: declare which node the graph should run first.
    /// Equivalent to `addEdge(from: .start, to: name)`.
    public mutating func setEntry(_ name: String) {
        self.addEdge(from: Self.start, to: name)
    }

    /// Add a fan-out edge from `source` that runs each branch node in
    /// `branches` concurrently. Each branch receives the same input
    /// state (the `source` node's output) and returns its own
    /// `State`. Branch outputs are merged via registered reducers
    /// (see `addReducer`); fields without a reducer default to
    /// last-write-wins in branch declaration order. Control then
    /// transfers to `joinAt` with the merged state.
    public mutating func addParallelEdge(
        from source: String,
        branches: [String],
        joinAt: String
    ) {
        precondition(!branches.isEmpty, "Parallel edge must declare at least one branch")
        precondition(
            !branches.contains(Self.end),
            "Parallel branches cannot be `.end` directly — route to a join node first"
        )
        self.edges[source] = .parallel(branches: branches, join: joinAt)
    }

    /// Register a reducer for `keyPath`. When parallel branches
    /// produce divergent values for this field, the reducer is folded
    /// across them in declaration order: starting from the input
    /// state's value, each branch's value is merged in via
    /// `reducer(accumulated, branchValue)`.
    public mutating func addReducer<Value>(
        for keyPath: WritableKeyPath<State, Value> & Sendable,
        reducer: @Sendable @escaping (Value, Value) -> Value
    ) {
        let apply: @Sendable (_ existing: State, _ result: inout State) -> Void = { existing, result in
            let merged = reducer(existing[keyPath: keyPath], result[keyPath: keyPath])
            result[keyPath: keyPath] = merged
        }
        self.reducers.append(AnyReducer(apply: apply))
    }

    /// Validate the graph and produce a `CompiledStateGraph`. Throws
    /// `StateGraphError.invalidGraph` if entry / edge wiring is
    /// inconsistent (missing entry, edge pointing at unknown node, no
    /// path to `end`).
    public func build() throws -> CompiledStateGraph<State> {
        try Self.validate(nodes: self.nodes, edges: self.edges)
        return CompiledStateGraph(
            nodes: self.nodes,
            edges: self.edges,
            reducers: self.reducers
        )
    }

    // MARK: Private

    private var nodes: [String: Node<State>] = [:]
    private var edges: [String: Edge<State>] = [:]
    private var reducers: [AnyReducer<State>] = []

    private static func validate(
        nodes: [String: Node<State>],
        edges: [String: Edge<State>]
    ) throws {
        guard let entry = edges[start] else {
            throw StateGraphError.invalidGraph(
                "Graph has no entry — call setEntry(_:) or addEdge(from: .start, to: …)"
            )
        }
        try Self.validateEdge(entry, knownNodes: nodes)
        for (source, edge) in edges where source != Self.start {
            guard nodes[source] != nil else {
                throw StateGraphError.invalidGraph(
                    "Edge declared from unknown node '\(source)'"
                )
            }
            try Self.validateEdge(edge, knownNodes: nodes)
        }
        // Every registered node must have an outgoing edge so execution
        // doesn't strand mid-graph. Branch nodes referenced by a
        // parallel edge are an exception: they fold back into the
        // join node automatically and don't need their own outgoing
        // edge.
        let branchNodes = Self.collectBranchNodes(in: edges)
        for nodeName in nodes.keys
            where edges[nodeName] == nil && !branchNodes.contains(nodeName) {
            throw StateGraphError.invalidGraph(
                "Node '\(nodeName)' has no outgoing edge"
            )
        }
    }

    private static func collectBranchNodes(
        in edges: [String: Edge<State>]
    ) -> Set<String> {
        var result: Set<String> = []
        for (_, edge) in edges {
            if case let .parallel(branches, _) = edge {
                for branch in branches {
                    result.insert(branch)
                }
            }
        }
        return result
    }

    private static func validateEdge(
        _ edge: Edge<State>,
        knownNodes: [String: Node<State>]
    ) throws {
        switch edge {
        case let .static(target):
            try Self.validateTarget(target, knownNodes: knownNodes)
        case let .conditional(targets, _):
            for target in targets {
                try Self.validateTarget(target, knownNodes: knownNodes)
            }
        case let .parallel(branches, join):
            for branch in branches {
                try Self.validateTarget(branch, knownNodes: knownNodes)
            }
            try Self.validateTarget(join, knownNodes: knownNodes)
        }
    }

    private static func validateTarget(
        _ target: String,
        knownNodes: [String: Node<State>]
    ) throws {
        guard target == self.end || knownNodes[target] != nil else {
            throw StateGraphError.invalidGraph(
                "Edge points at unknown target '\(target)'"
            )
        }
    }
}

// MARK: - Node

struct Node<State: Sendable & Codable> {
    let name: String
    let run: @Sendable (State) async throws -> State
}

// MARK: - Edge

enum Edge<State: Sendable & Codable> {
    case `static`(String)
    case conditional(targets: Set<String>, route: @Sendable (State) -> String)
    case parallel(branches: [String], join: String)
}

// MARK: - AnyReducer

/// Type-erased reducer that knows how to merge one field of `State`
/// from a parallel branch's output into an accumulating result.
struct AnyReducer<State: Sendable & Codable> {
    /// Read the field from `existing` and `result`, compute the
    /// merged value, write it back into `result`.
    let apply: @Sendable (_ existing: State, _ result: inout State) -> Void
}

// MARK: - StateGraphError

public enum StateGraphError: Error, Sendable, Equatable {
    case invalidGraph(String)
    case invalidRoute(from: String, returned: String, allowed: Set<String>)
    case stepLimitExceeded(limit: Int)
    case noEdgeFromNode(String)
}
