# Layer 6 — StateGraph

`StateGraph<State>` is Aria's optional graph orchestration layer. It is intended for branching, multi-node workflows that don't fit cleanly into the linear tool-calling loop of `Agent`.

This layer is **optional**. Most agent applications never need it. Build with `Agent` first; reach for `StateGraph` only when the linear loop becomes a bad fit.

## When to use `StateGraph`

| Pattern | `Agent`? | `StateGraph`? |
|---|---|---|
| Chat with tools | Yes | No |
| Single-shot question + tools | Yes | No |
| Sequential pipeline (research → summarize → review) | Either; `pipe` is simpler | Maybe |
| Branching: "if classified as X, do A, else do B" | Awkward | Yes |
| Multi-agent supervisor coordinating workers | Yes (subagents-as-tools) | Yes (cleaner if many) |
| Long-running workflow with HITL interrupts at named nodes | No | Yes |
| Parallel research (fan-out, fan-in) | No | Yes |

If a problem can be expressed as `pipe` of two or three Runnables, use that. If it needs explicit branching or fan-out, use `StateGraph`.

## Core types

```swift
public struct StateGraph<State: Codable & Sendable>: Sendable {
    public init(state: State.Type)

    @discardableResult
    public mutating func node<R: Runnable>(
        _ name: String,
        runnable: R
    ) -> Self where R.Input == State, R.Output == StateUpdate<State>

    @discardableResult
    public mutating func edge(_ from: String, _ to: String) -> Self

    @discardableResult
    public mutating func conditionalEdge(
        from: String,
        decide: @Sendable @escaping (State) async throws -> String
    ) -> Self

    @discardableResult
    public mutating func entry(_ node: String) -> Self

    @discardableResult
    public mutating func terminal(_ node: String) -> Self

    public func compile() throws -> CompiledStateGraph<State>
}
```

## `StateUpdate`

Nodes return state updates rather than full state. The graph applies updates via channels.

```swift
public struct StateUpdate<State: Sendable>: Sendable {
    public let updates: [PartialKeyPath<State>: any Sendable]
    public let nextHint: String?         // optional override of routing
}
```

Channels (next section) determine how updates merge into state.

## Channels (state merging)

A channel describes how updates to a particular field merge.

```swift
public protocol Channel<Value>: Sendable {
    associatedtype Value: Sendable
    func merge(current: Value, update: Value) -> Value
}

public struct LastWriteWins<V: Sendable>: Channel { ... }
public struct Append<V: Sendable, Element: Sendable>: Channel where V == [Element] { ... }
public struct Sum<V: Numeric & Sendable>: Channel { ... }
```

State fields are annotated with channels via property wrappers or a separate registration step:

```swift
struct ResearchState: Codable, Sendable {
    @Channeled(Append<[Finding]>())
    var findings: [Finding] = []

    @Channeled(LastWriteWins())
    var summary: String = ""
}
```

(The exact annotation mechanism — property wrapper vs. registration — is a future decision. The semantic is fixed.)

## Compiled graph

```swift
public struct CompiledStateGraph<State: Codable & Sendable>: Runnable {
    public typealias Input = State
    public typealias Output = StateUpdate<State>

    public func stream(
        _ input: State,
        options: RunOptions
    ) -> AsyncThrowingStream<StateUpdate<State>, Error>
}
```

A compiled graph is itself a `Runnable<State, StateUpdate<State>>`. Composability all the way down.

## Execution model

The graph executes in **supersteps** (borrowed from Pregel):

1. Identify the set of nodes that are ready to run (entry node on first step; nodes pointed to by edges from completed nodes thereafter).
2. Run all ready nodes concurrently (each is a `Runnable<State, StateUpdate<State>>`).
3. Merge their `StateUpdate`s into state via channels.
4. Yield the merged update.
5. Determine next ready set via edges and conditional edges.
6. If no ready nodes remain, terminate.

This gives you natural parallelism (fan-out at a junction runs concurrently) and a clean checkpointing story (state is well-defined between supersteps).

## Conditional edges

```swift
graph
    .node("classify", classifyRunnable)
    .conditionalEdge(from: "classify", decide: { state in
        state.classification == .research ? "research" : "answer"
    })
    .node("research", researchRunnable)
    .node("answer", answerRunnable)
    .edge("research", "answer")
    .terminal("answer")
```

## Subgraphs

A graph can include another graph as a node (since `CompiledStateGraph` is a `Runnable`):

```swift
let researchGraph: CompiledStateGraph<ResearchState> = ...
let mainGraph = StateGraph(state: AppState.self)
    .node("research_subgraph", researchGraph.adapted(to: AppState.self, /* lens */))
```

The lens (in/out adapter between outer state and inner state) is provided as a small adapter Runnable. We do not introduce a full lens library — adapters are written by hand for the few subgraph cases that exist.

## Checkpointing integration

`StateGraph` integrates with Layer 4's `Checkpointer`:

```swift
public struct StateGraphConfig: Sendable {
    public var checkpointer: (any Checkpointer)?
    public var checkpointAfterEverySuperstep: Bool   // default true
}
```

Checkpoints are written between supersteps, never mid-superstep. This guarantees that resuming from a checkpoint always lands on a clean boundary.

## Human-in-the-loop interrupts

Nodes can interrupt the graph by emitting a special `StateUpdate` with `nextHint = "__interrupt__"`. The graph stops; the latest checkpoint records pre-interrupt state; the consumer presents the question; on resume (`graph.stream(state, options: .init(resumeFromCheckpoint: id))`), execution continues from that checkpoint.

## Example: research-and-summarize graph

```swift
struct ResearchState: Codable, Sendable {
    @Channeled(LastWriteWins())
    var query: String = ""

    @Channeled(Append<[Finding]>())
    var findings: [Finding] = []

    @Channeled(LastWriteWins())
    var summary: String = ""
}

var graph = StateGraph(state: ResearchState.self)

graph
    .entry("plan")
    .node("plan", PlanRunnable())               // emits subqueries
    .node("research_a", ResearchRunnable())     // run in parallel after plan
    .node("research_b", ResearchRunnable())
    .node("research_c", ResearchRunnable())
    .edge("plan", "research_a")
    .edge("plan", "research_b")
    .edge("plan", "research_c")
    .node("summarize", SummarizeRunnable())     // fan-in
    .edge("research_a", "summarize")
    .edge("research_b", "summarize")
    .edge("research_c", "summarize")
    .terminal("summarize")

let compiled = try graph.compile()
let final = try await compiled.invoke(ResearchState(query: "..."), options: .init())
print(final.summary)
```

The fan-out (plan → 3 research nodes) and fan-in (3 research nodes → summarize) happen automatically based on edges. The `Append` channel merges three `findings` updates into one combined list.

## What this layer does NOT include

- A built-in graph visualization or studio. Out of scope; emit graph topology data and let consumers visualize.
- Distributed execution. Aria runs locally; graphs run in one process.
- A DSL for graph construction. The fluent builder above is the API.
- Time-travel UI. The data is there (via `Checkpointer`); the UI is the consumer's job.

## Testing

`StateGraph` tests use trivial Runnables for nodes:

```swift
struct AddOne: Runnable {
    func invoke(_ input: Int, options: RunOptions) async throws -> StateUpdate<TestState> {
        // ...
    }
}
```

Graph tests verify topology, channel merging, conditional routing, and checkpointing. All run on Linux.

## When NOT to build this

`StateGraph` is the most complex layer. Until you have a concrete use case in your application that needs it, don't implement it. The agent loop covers the 80% case; defer this layer until the 80% becomes 60%.

If implemented, version it carefully — graph DSL changes are breaking for users.

## Future considerations

- **Streaming intermediate updates per node.** Today nodes return one `StateUpdate`. Streaming nodes (a node that emits multiple updates over time) is plausible.
- **Edge weights / priorities.** When multiple conditional edges fire, today the order is "all of them, in parallel." Priority/weight could disambiguate.
- **External graph schemas.** Defining graphs in JSON/YAML for hot-reload. Probably not Aria's job.
- **Subgraph lenses.** A small lens utility may emerge if subgraphs become common.
