import Foundation

// MARK: - WorkflowGraphLayout

/// Pure positional layout for a `Workflow` rendered as a
/// directed graph. The graph view (slice 13) calls
/// `compute(for:)` once on workflow load and renders against
/// the returned positions; subsequent edits recompute.
///
/// Layering is longest-path: each node sits one row below
/// its deepest predecessor. Within a row, nodes are placed
/// left-to-right in workflow declaration order — gives a
/// deterministic, reviewable layout for linear chains and
/// reasonable defaults for branches / parallels.
///
/// Edge synthesis is structural — explicit `Workflow.edges`
/// take priority; otherwise we walk a "main chain" of nodes
/// (the ones not declared inside a branch / parallel), pair
/// each step with the next, and insert fan-out + join edges
/// when the step is a `BranchStep` / `ParallelStep`. This
/// matches how the runner walks the workflow in the linear-
/// default case.
public struct WorkflowGraphLayout: Sendable, Equatable {
    // MARK: Lifecycle

    private init(
        positions: [UUID: Position],
        edges: [Edge],
        rowCount: Int,
        columnsPerRow: [Int: Int],
        columnCount: Int
    ) {
        self.positions = positions
        self.edges = edges
        self.rowCount = rowCount
        self.columnsPerRow = columnsPerRow
        self.columnCount = columnCount
    }

    // MARK: Public

    public struct Position: Sendable, Hashable {
        public let nodeID: UUID
        public let row: Int
        public let column: Int
    }

    public struct Edge: Sendable, Hashable {
        public let from: UUID
        public let to: UUID
    }

    public let positions: [UUID: Position]
    public let edges: [Edge]
    public let rowCount: Int
    public let columnsPerRow: [Int: Int]
    public let columnCount: Int

    /// Build a layout from a workflow.
    public static func compute(for workflow: Workflow) -> WorkflowGraphLayout {
        let nodeIDs = workflow.nodes.map(\.id)
        let nodeIDSet = Set(nodeIDs)
        let edges = Self.collectEdges(workflow: workflow, nodeIDs: nodeIDSet)
        let layers = Self.assignLayers(nodeIDs: nodeIDs, edges: edges)
        let declarationOrder = Dictionary(
            uniqueKeysWithValues: nodeIDs.enumerated().map { ($1, $0) }
        )

        var byLayer: [Int: [UUID]] = [:]
        for (id, layer) in layers {
            byLayer[layer, default: []].append(id)
        }
        for layer in byLayer.keys {
            byLayer[layer]?.sort {
                (declarationOrder[$0] ?? 0) < (declarationOrder[$1] ?? 0)
            }
        }

        var positions: [UUID: Position] = [:]
        var columnsPerRow: [Int: Int] = [:]
        var maxColumn = 0
        for (layer, ids) in byLayer {
            columnsPerRow[layer] = ids.count
            maxColumn = max(maxColumn, ids.count)
            for (column, id) in ids.enumerated() {
                positions[id] = Position(nodeID: id, row: layer, column: column)
            }
        }

        let rowCount = (layers.values.max() ?? -1) + 1
        return WorkflowGraphLayout(
            positions: positions,
            edges: Array(edges).sorted(by: Self.edgeOrder),
            rowCount: rowCount,
            columnsPerRow: columnsPerRow,
            columnCount: maxColumn
        )
    }

    // MARK: Private

    private static func edgeOrder(_ lhs: Edge, _ rhs: Edge) -> Bool {
        if lhs.from != rhs.from {
            return lhs.from.uuidString < rhs.from.uuidString
        }
        return lhs.to.uuidString < rhs.to.uuidString
    }

    private static func collectEdges(workflow: Workflow, nodeIDs: Set<UUID>) -> Set<Edge> {
        if !workflow.edges.isEmpty {
            var edges: Set<Edge> = []
            for edge in workflow.edges where nodeIDs.contains(edge.from)
                && nodeIDs.contains(edge.to) {
                edges.insert(Edge(from: edge.from, to: edge.to))
            }
            return edges
        }
        return self.synthesizeEdges(workflow: workflow, nodeIDs: nodeIDs)
    }

    private static func synthesizeEdges(
        workflow: Workflow,
        nodeIDs: Set<UUID>
    ) -> Set<Edge> {
        var edges: Set<Edge> = []
        let branchChildIDs = Self.branchAndParallelChildIDs(workflow.nodes)
        let mainChain = workflow.nodes.filter { !branchChildIDs.contains($0.id) }

        for (current, next) in zip(mainChain, mainChain.dropFirst()) {
            let fanOuts = Self.fanOutChildren(current, nodeIDs: nodeIDs)
            if fanOuts.isEmpty {
                edges.insert(Edge(from: current.id, to: next.id))
            } else {
                for child in fanOuts {
                    edges.insert(Edge(from: current.id, to: child))
                }
                for joinSource in Self.joinSources(current, nodeIDs: nodeIDs) {
                    edges.insert(Edge(from: joinSource, to: next.id))
                }
            }
        }

        // The tail of the main chain may itself fan out (e.g. a
        // workflow that ends with a Parallel step); draw those
        // edges even though there's no convergence node to join
        // back to.
        if let tail = mainChain.last {
            for child in Self.fanOutChildren(tail, nodeIDs: nodeIDs) {
                edges.insert(Edge(from: tail.id, to: child))
            }
        }

        // Chain within each branch list so multi-step branches
        // render as connected sub-chains.
        for node in workflow.nodes {
            if case let .branch(step) = node {
                Self.appendChain(step.trueBranch, into: &edges, allowed: nodeIDs)
                Self.appendChain(step.falseBranch, into: &edges, allowed: nodeIDs)
            }
        }

        return edges
    }

    private static func appendChain(
        _ ids: [UUID],
        into edges: inout Set<Edge>,
        allowed: Set<UUID>
    ) {
        for (lhs, rhs) in zip(ids, ids.dropFirst())
            where allowed.contains(lhs) && allowed.contains(rhs) {
            edges.insert(Edge(from: lhs, to: rhs))
        }
    }

    private static func branchAndParallelChildIDs(_ nodes: [WorkflowNode]) -> Set<UUID> {
        var ids: Set<UUID> = []
        for node in nodes {
            switch node {
            case let .branch(step):
                ids.formUnion(step.trueBranch)
                ids.formUnion(step.falseBranch)
            case let .parallel(step):
                ids.formUnion(step.children)
            default:
                break
            }
        }
        return ids
    }

    private static func fanOutChildren(
        _ node: WorkflowNode,
        nodeIDs: Set<UUID>
    ) -> [UUID] {
        switch node {
        case let .branch(step):
            var children: [UUID] = []
            if let first = step.trueBranch.first, nodeIDs.contains(first) {
                children.append(first)
            }
            if let first = step.falseBranch.first, nodeIDs.contains(first) {
                children.append(first)
            }
            return children
        case let .parallel(step):
            return step.children.filter { nodeIDs.contains($0) }
        default:
            return []
        }
    }

    private static func joinSources(
        _ node: WorkflowNode,
        nodeIDs: Set<UUID>
    ) -> [UUID] {
        switch node {
        case let .branch(step):
            var sources: [UUID] = []
            if let last = step.trueBranch.last, nodeIDs.contains(last) {
                sources.append(last)
            }
            if let last = step.falseBranch.last, nodeIDs.contains(last) {
                sources.append(last)
            }
            return sources
        case let .parallel(step):
            return step.children.filter { nodeIDs.contains($0) }
        default:
            return []
        }
    }

    private static func assignLayers(
        nodeIDs: [UUID],
        edges: Set<Edge>
    ) -> [UUID: Int] {
        var inDegree: [UUID: Int] = Dictionary(
            uniqueKeysWithValues: nodeIDs.map { ($0, 0) }
        )
        var adjacency: [UUID: [UUID]] = [:]
        for edge in edges {
            inDegree[edge.to, default: 0] += 1
            adjacency[edge.from, default: []].append(edge.to)
        }
        var queue = nodeIDs.filter { inDegree[$0] == 0 }
        var layers: [UUID: Int] = Dictionary(
            uniqueKeysWithValues: queue.map { ($0, 0) }
        )
        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            let currentLayer = layers[current] ?? 0
            for next in adjacency[current] ?? [] {
                layers[next] = max(layers[next] ?? 0, currentLayer + 1)
                inDegree[next, default: 0] -= 1
                if inDegree[next] == 0 {
                    queue.append(next)
                }
            }
        }
        // Defensive fallback for cyclic graphs (shouldn't happen
        // for valid workflows but a hand-edited JSON could
        // produce one). Drop unvisited nodes into declaration
        // order so they at least render somewhere.
        for (index, id) in nodeIDs.enumerated() where layers[id] == nil {
            layers[id] = index
        }
        return layers
    }
}
