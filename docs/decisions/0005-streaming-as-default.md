# ADR 0005 — Streaming is the default output shape

**Status:** Accepted
**Date:** 2026-05-09

## Context

Aria's primary use case is real-time agent UX: users see tokens appear, tool calls being made, results coming back, all as they happen. Streaming is not a nice-to-have; it is the default expected behavior.

The question: should we have parallel APIs for streaming and non-streaming, or pick one canonical shape?

## Decision

Streaming is the canonical output shape. Every component that *could* stream, *does* stream. `AsyncThrowingStream<Output, Error>` is the universal output type. Non-streaming consumers collect the stream:

```swift
let result = try await Array(runnable.stream(input, options: .init()))
```

The `Runnable` protocol still provides an `invoke(...)` convenience that returns a single value, but it is implemented in terms of `stream` by default. Concrete types may override `invoke` for efficiency where it makes sense.

## Rationale

1. **One code path is dramatically simpler.** Two parallel APIs (stream and non-stream) double the surface, double the bugs, and force every implementation to maintain both.

2. **Streaming is a superset.** A non-streaming producer is a streaming producer that yields once. The reverse is not true.

3. **`AsyncSequence` and `AsyncThrowingStream` are first-class in Swift.** They compose cleanly with Swift Concurrency, support cancellation, and have native syntax (`for try await`).

4. **The agent loop fundamentally streams.** Tokens, tool calls, tool results, step boundaries — all events. Building the agent on top of a single `AsyncStream<AgentEvent>` is the right shape.

5. **SwiftUI integrates naturally with streams.** `AsyncSequence` consumers in `.task { ... }` are idiomatic. Building a non-streaming-first API and then bolting on streaming would be backwards.

## Consequences

### Positive

- Single source of truth for output behavior.
- Agents stream events natively without adapter layers.
- UI integration is straightforward.
- Cancellation propagates cleanly via `Task.isCancelled`.

### Negative

- Some components (a `PromptTemplate` that just renders a string) feel artificial as streams. They yield once and finish.
- Consumers who only want a single value pay slight syntactic overhead (`Array(stream).last`).
- The default `invoke` (collect last value) is a convention that may not fit all cases — components that produce *intermediate* results during streaming and a *different* final result must override.

### Mitigations

- The convenience `invoke(...)` method handles the single-value case ergonomically.
- The default-impl convention (last yielded value) is documented in the Runnable layer and ADRs.
- Producers that need different invoke vs. stream semantics override `invoke`.

## Concrete patterns enabled

### Token streaming to UI

```swift
for try await event in agent.stream(.message(.user(input)), options: .init()) {
    if case .textDelta(let chunk) = event {
        await uiState.appendText(chunk)
    }
}
```

### Collecting a single result

```swift
let response = try await Array(chain.stream(input, options: .init())).last
```

### Cancellation

```swift
let task = Task {
    for try await event in agent.stream(...) { ... }
}
// Later:
task.cancel()  // propagates through provider, tool execution, everything
```

### Composition

```swift
// Each stage in a pipe sees the upstream's final value.
// For per-chunk processing, use mapStream.
chain.mapStream { chunk in chunk.uppercased() }
```

## Alternatives considered

### A. Two parallel APIs (`invoke` and `stream`)
Rejected. Doubles surface, doubles bugs. LangChain.js does this and pays the cost.

### B. Non-streaming as default with optional streaming opt-in
Rejected. Backwards from how agents naturally work. Forces `invoke()` to be the primary API and `stream()` to be a second-class extension.

### C. Use Combine `Publisher` instead of `AsyncSequence`
Rejected. Combine is Apple-only (conflicts with ADR 0002). `AsyncSequence` is cross-platform and the language-blessed primitive going forward.

### D. Custom event-emitter pattern (delegate or callback-based)
Rejected. Less composable than `AsyncSequence`. Pre-Concurrency idiom.

## Independence note

The decision to make streaming the default output shape is dictated by Swift's idioms and the nature of agent UX. It is not derived from any specific framework's design. Many systems stream agent output; the choice to use `AsyncThrowingStream` specifically is the natural Swift fit.
