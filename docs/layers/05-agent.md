# Layer 5 — Agent

The agent is the orchestrator: it ties an `LLMProvider`, a set of `Tool`s, optional memory, and middleware into a tool-calling control loop.

`Agent` is itself a `Runnable<AgentInput, AgentEvent>`. That's the unification point — agents compose with everything else in Aria.

## `AgentConfig`

```swift
public struct AgentConfig: Sendable {
    // Required
    public var provider: any LLMProvider
    public var tools: [AnyTool]

    // Behavior
    public var systemPrompt: String?
    public var generationOptions: GenerationOptions

    // Memory (all optional)
    public var history: (any ChatHistory)?
    public var checkpointer: (any Checkpointer)?
    public var memoryStore: (any MemoryStore)?
    public var historyPolicy: HistoryPolicy

    // Extension
    public var middleware: [any AgentMiddleware]

    // Limits
    public var maxSteps: Int                        // default 10
    public var maxToolExecutionsPerStep: Int        // default 8
    public var parallelToolCalls: Bool              // default true
    public var toolTimeout: Duration                // default .seconds(60)

    public init(...)
}
```

## `AgentInput`

What you send to an agent.

```swift
public enum AgentInput: Sendable {
    case message(Message)
    case messages([Message])
    case resume(threadId: String, fromCheckpointId: String? = nil)
}
```

- `.message`: append this message to history (if configured) and run.
- `.messages`: append all of these and run.
- `.resume`: load state from checkpointer and continue.

## `AgentState`

The state the agent threads through the loop.

```swift
public struct AgentState: Codable, Sendable {
    public var threadId: String
    public var messages: [Message]
    public var stepCount: Int
    public var scratchpad: [String: JSONValue]
    public var pendingToolCalls: [ToolCall]
    public var lastFinishReason: FinishReason?
}
```

`scratchpad` is the per-run mutable bag for middleware to share data (e.g., RAG retrieved context).

## `AgentMiddleware`

Hooks into the loop without modifying the agent.

```swift
public protocol AgentMiddleware: Sendable {
    func beforeRun(_ state: AgentState) async throws -> AgentState
    func beforeStep(_ state: AgentState) async throws -> AgentState
    func afterStep(_ state: AgentState, events: [AgentEvent]) async throws -> AgentState
    func afterRun(_ state: AgentState, finalEvent: AgentEvent) async throws -> AgentState
}

extension AgentMiddleware {
    public func beforeRun(_ state: AgentState) async throws -> AgentState { state }
    public func beforeStep(_ state: AgentState) async throws -> AgentState { state }
    public func afterStep(_ state: AgentState, events: [AgentEvent]) async throws -> AgentState { state }
    public func afterRun(_ state: AgentState, finalEvent: AgentEvent) async throws -> AgentState { state }
}
```

Default no-op for each method; implementations override what they need.

### Built-in middleware (in `Aria`)

Auto-installed by `Agent.init` when their dependencies are present:

- `LoggingMiddleware` — emits `swift-log` lines for each step.
- `CheckpointMiddleware` — writes a checkpoint after every step (if `checkpointer` is configured).
- `HistoryMiddleware` — loads persisted history on `beforeRun` and writes new messages to `ChatHistory` after every step (if `history` is configured).

User-composable (you add these to `AgentConfig.middleware` as needed):

- `HistoryWindowMiddleware(maxTurns:maxTokens:tokenCounter:)` — caps the message slice the provider sees per step. System messages always survive; tool messages stay paired with their assistant call; the most recent user/assistant pair always survives even if both caps want to drop them. Default token counter is a 4-chars-per-token heuristic; inject a real tokenizer when you need exact accounting. Pair with `HistoryMiddleware` (loads from store) — this middleware shapes what's sent on the wire, never persistence.
- `HistorySummarizationMiddleware(triggerAfterTurns:keepRecentTurns:summarizer:)` — when the non-system message count exceeds `triggerAfterTurns`, compresses the older portion into a single `.system` summary message. The summarizer is a caller-supplied async closure that takes the older slice and returns the summary text (typically a cheap LLM call). Per-process result cache so re-running with the same slice doesn't re-summarize. Fail-open: a summarizer error leaves state untouched and the turn proceeds with the full transcript.
- `RAGMiddleware(memoryStore:namespace:topK:onRecall:)` — on `beforeStep`, embeds the latest user message, recalls top-K matches from the per-user `MemoryStore` namespace, and prepends them as a fresh `.system` message. The optional `onRecall` callback lets the UI show which memories were injected.
- `FactExtractionMiddleware(memory:namespace:dedupSimilarityThreshold:extractor:)` — on `afterStep`, scans the latest user message through a caller-supplied extractor (typically a cheap LLM) and writes returned facts into the `MemoryStore`. Optional similarity-based dedup against existing memories (default 0.9) so the same fact isn't stored twice. Stored facts get `metadata["source"] = "auto_extracted"` and `metadata["thread_id"]` for audit / different retention policies. Errors are swallowed — the user has already seen the reply.

The typical chain on a chat surface that wants the full memory stack:

1. `HistoryMiddleware` — load persisted history
2. `HistorySummarizationMiddleware` — compress older portion
3. `HistoryWindowMiddleware` — hard cap (belt-and-braces)
4. `RAGMiddleware` — prepend recalled facts
5. `FactExtractionMiddleware` — mine the user turn after the reply

Pair with `HistoryRetentionPolicy` (Layer 4) on app launch to bound the disk side.

### Built-in middleware (in `AriaApple`)

- `OSLogMiddleware` — sugar over `LoggingMiddleware` using `OSLog`.
- `MetricKitMiddleware` — emits MetricKit signposts for each step.

## `Agent`

```swift
public actor Agent: Runnable {
    public typealias Input = AgentInput
    public typealias Output = AgentEvent

    public init(config: AgentConfig)

    public nonisolated func stream(
        _ input: AgentInput,
        options: RunOptions
    ) -> AsyncThrowingStream<AgentEvent, Error>
}
```

`Agent` is an actor so its internal state (in-flight runs, sequencing) is data-race-free. The `stream` function is `nonisolated` because it constructs an `AsyncThrowingStream` and dispatches work into a `Task`.

## The control loop

The heart of the agent. Pseudocode:

```
1. Set up: build initial AgentState from AgentInput
   - new run: load history (if configured), append input, run beforeRun middleware
   - resume: load state from checkpointer, continue

2. Yield .stepStart(0)

3. For step in 0..<maxSteps:
     a. Run beforeStep middleware
     b. Apply HistoryPolicy to select messages for the model
     c. Yield .assistantStart
     d. For try await event in provider.stream(messages, tools, options):
          - case textDelta(s): yield .textDelta(s); append to growing assistant message
          - case toolCallStart(c): start collecting; yield .toolCallRequested(c)
          - case toolCallDelta(id, d): merge into pending tool call
          - case toolCallEnd(id): finalize tool call
          - case messageStop(reason): break
     e. Append the final assistant message to state.messages
     f. If no tool calls: yield .finish(reason); run afterStep middleware; break
     g. Execute tools (parallel if config allows):
          for each toolCall:
            yield .toolExecutionStart(id)
            execute (with timeout, with cancellation)
            yield .toolExecutionEnd(id, result)
            append tool result message to state.messages
     h. Increment stepCount
     i. Run afterStep middleware
     j. Yield .stepEnd(step)

4. If loop exited due to maxSteps: yield .finish(.maxStepsReached); set error

5. Run afterRun middleware

6. Stream finishes
```

## Translating `ProviderEvent` → `AgentEvent`

Most events translate one-to-one, but some require buffering:

| ProviderEvent | AgentEvent |
|---|---|
| `messageStart` | `assistantStart` |
| `textDelta` | `textDelta` |
| `toolCallStart` | (collected; emitted as `toolCallRequested` after `toolCallEnd`) |
| `toolCallDelta` | (merged into pending) |
| `toolCallEnd` | `toolCallRequested(finalToolCall)` |
| `messageStop(reason)` | (used for control flow; emits `.finish` later if no tool calls) |
| `usage` | (recorded in state metadata; not emitted by default) |

Tool calls are the tricky case: the agent must wait for the full call (with arguments parsed) before it can execute. Streaming tool argument deltas to the user is uncommon and not exposed by default.

## Tool execution

```swift
private func executeTools(
    _ calls: [ToolCall],
    config: AgentConfig,
    context: ToolContext
) async throws -> [(ToolCall, ToolExecutionResult)] {
    if config.parallelToolCalls {
        return try await withThrowingTaskGroup(of: (ToolCall, ToolExecutionResult).self) { group in
            for call in calls {
                group.addTask { try await self.executeOne(call, config: config, context: context) }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
    } else {
        var results: [(ToolCall, ToolExecutionResult)] = []
        for call in calls {
            results.append(try await executeOne(call, config: config, context: context))
        }
        return results
    }
}
```

Each tool execution:

- Wrapped in `withTimeout(config.toolTimeout)`.
- Errors caught and converted to a `ToolExecutionResult(isError: true, ...)`. The agent does not propagate the error up — failed tools become `tool` messages with error content, and the model can react.
- Cancellation honored: if the agent's `RunOptions.cancellation` is cancelled, in-flight tools are cancelled too.

## Cancellation

The agent honors three cancellation paths:

1. The Swift `Task` running the stream is cancelled — `Task.isCancelled` checked at every yield point.
2. `RunOptions.cancellation.cancel()` — checked at the same yield points.
3. `RunOptions.deadline` exceeded — wrapped via `withTimeout`.

When cancelled:

- In-flight provider stream is cancelled.
- In-flight tool executions are cancelled.
- The stream emits `AgentEvent.error(.cancelled)` and finishes.
- The latest checkpoint is *not* updated (cancellation does not corrupt state).

## Capability adaptation

If `provider.capabilities.supportsToolUse == false`, the agent uses a fallback strategy:

- Inject a system prompt instructing the model to emit JSON tool calls in a specific schema.
- Parse the assistant's text output for tool calls.
- The user-facing API is identical.

If `provider.capabilities.supportsParallelToolCalls == false` and `config.parallelToolCalls == true`, the agent silently serializes (config asks for parallel; provider doesn't allow; serialize).

## Subagents

An agent is a `Runnable<AgentInput, AgentEvent>`. To use one agent inside another, wrap it as a tool:

```swift
struct ResearcherTool: Tool {
    typealias Input = String
    typealias Output = String

    let agent: Agent

    static var name = "research"
    static var description = "Research a topic via subagent"
    static var inputSchema: JSONSchema = .string()

    func call(_ input: String, context: ToolContext) async throws -> String {
        var lastText = ""
        for try await event in agent.stream(.message(.user(input)), options: RunOptions(parentRunId: context.runId)) {
            if case .textDelta(let s) = event { lastText += s }
        }
        return lastText
    }
}
```

This is the basic supervisor pattern, no special framework support required. The agent's `Runnable` conformance carries the weight.

## Concrete example

```swift
let agent = Agent(config: AgentConfig(
    provider: FoundationModelsProvider(model: .systemDefault),
    tools: [AnyTool(WeatherTool(httpClient: client)), AnyTool(CalendarTool())],
    systemPrompt: "You are a helpful assistant.",
    history: SwiftDataChatHistory(...),
    checkpointer: SwiftDataCheckpointer(...),
    middleware: [RAGMiddleware(memoryStore: memory, namespace: ["user", userId], topK: 5)]
))

for try await event in agent.stream(.message(.user("What's on my calendar tomorrow?")), options: .init()) {
    switch event {
    case .textDelta(let s):
        await ui.appendText(s)
    case .toolCallRequested(let call):
        await ui.showToolBadge(call.name)
    case .toolExecutionEnd(let id, let result):
        await ui.completeToolBadge(id, success: !result.isError)
    case .finish(let reason):
        await ui.markComplete(reason)
    case .error(let err):
        await ui.showError(err)
    default:
        break
    }
}
```

## What this layer does NOT include

- Branching/multi-node graphs (Layer 6).
- Concrete provider, memory, or tool implementations.
- UI rendering.
- Tracing/observability platforms.

## Testing

End-to-end agent tests using `MockLLMProvider`:

```swift
let provider = MockLLMProvider(scripted: [
    [.assistantStart, .textDelta("Let me check."), .toolCallStart(...), .toolCallEnd(id: "t1"), .messageStop(.toolUse)],
    [.assistantStart, .textDelta("It's 72°F."), .messageStop(.endTurn)]
])
let agent = Agent(config: AgentConfig(
    provider: provider,
    tools: [AnyTool(MockWeatherTool())],
    history: InMemoryChatHistory()
))

var events: [AgentEvent] = []
for try await event in agent.stream(.message(.user("weather?")), options: .init()) {
    events.append(event)
}

XCTAssertTrue(events.contains { if case .toolCallRequested = $0 { return true } else { return false } })
XCTAssertTrue(events.contains { if case .finish = $0 { return true } else { return false } })
```

These tests run on Linux.

## Future considerations

- **Streaming tool arguments to the user.** Some UIs want to show tool args as they're generated. Add an opt-in `AgentEvent.toolCallArgumentsDelta(id:, delta:)`.
- **Cost tracking middleware.** Easy to write as a middleware that watches `usage` events; not core.
- **Step retries.** If the model fails mid-step, today the whole run errors. A middleware could retry the step. Defer until needed.
- **Speculative tool execution.** When the model emits a tool call, optimistically execute likely follow-up tools in parallel. Advanced; defer.
