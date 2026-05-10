import Foundation

// MARK: - StateGraph

/// A directed graph of named nodes that operate on a typed `State`
/// value. Nodes execute sequentially: each one receives the current
/// state and returns a new state, then control passes along whichever
/// edge applies until a node leads to `StateGraph.end`.
///
/// V1 limitations: nodes return a full `State` (no partial updates or
/// reducers), execution is sequential (no fan-out), and there is no
/// resume-from-checkpoint integration. These are tracked as follow-ups.
///
/// Build with `addNode` / `addEdge` / `addConditionalEdge` / `setEntry`,
/// then call `build()` to validate the graph and produce a
/// `CompiledStateGraph` that can stream events.
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

    /// Validate the graph and produce a `CompiledStateGraph`. Throws
    /// `StateGraphError.invalidGraph` if entry / edge wiring is
    /// inconsistent (missing entry, edge pointing at unknown node, no
    /// path to `end`).
    public func build() throws -> CompiledStateGraph<State> {
        try Self.validate(nodes: self.nodes, edges: self.edges)
        return CompiledStateGraph(nodes: self.nodes, edges: self.edges)
    }

    // MARK: Private

    private var nodes: [String: Node<State>] = [:]
    private var edges: [String: Edge<State>] = [:]

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
        // doesn't strand mid-graph.
        for nodeName in nodes.keys where edges[nodeName] == nil {
            throw StateGraphError.invalidGraph(
                "Node '\(nodeName)' has no outgoing edge"
            )
        }
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
}

// MARK: - StateGraphError

public enum StateGraphError: Error, Sendable, Equatable {
    case invalidGraph(String)
    case invalidRoute(from: String, returned: String, allowed: Set<String>)
    case stepLimitExceeded(limit: Int)
    case noEdgeFromNode(String)
}
