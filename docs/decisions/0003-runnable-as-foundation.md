# ADR 0003 — `Runnable<Input, Output>` as the composability primitive

**Status:** Accepted
**Date:** 2026-05-09

## Context

The library composes prompts, models, output parsers, retrievers, tools, and agents. We need a single shape that all of these conform to, so that:

- Users can `pipe` them together uniformly.
- Cross-cutting concerns (retries, timeouts, observability, caching) attach as decorators in one place.
- Agents can be embedded as components in larger compositions (an agent is just a Runnable).
- Type checks at the API boundary catch shape mismatches at compile time.

## Decision

Define a protocol:

```swift
public protocol Runnable<Input, Output>: Sendable {
    associatedtype Input: Sendable
    associatedtype Output: Sendable
    func invoke(_ input: Input, options: RunOptions) async throws -> Output
    func stream(_ input: Input, options: RunOptions) -> AsyncThrowingStream<Output, Error>
}
```

Every component that maps input to output conforms. Provide combinators (`pipe`, `map`, `parallel`, `withRetry`, `withTimeout`, `withObserver`, `withCache`) as protocol extensions.

## Rationale

1. **A single composability primitive is multiplicative in value.** With one shape, every decorator works on every component. Without it, each layer reinvents wrappers.

2. **Swift's protocol-with-associated-types fits this exactly.** We get type-safe `pipe` (compile-time mismatch detection) without runtime introspection or typed dictionaries.

3. **The pattern is well-precedented.** Java's `Function<T, R>`, RxSwift's `Observable`, Combine's `Publisher`, async iterator protocols across languages — the "input → output, possibly streaming" abstraction is a converged design.

4. **The pattern composes cleanly with Swift Concurrency.** `AsyncThrowingStream` is the universal output; non-streaming consumers collect it; streaming consumers iterate.

5. **Both `invoke` and `stream` with mutual defaults reduces friction.** Concrete types implement whichever is natural; the other is provided as a default.

## Consequences

### Positive

- Uniform composition — every chain looks the same.
- Decorators are reusable across all components.
- Agents are first-class citizens in the composition algebra (an agent is a `Runnable<AgentInput, AgentEvent>`).
- The API surface is small and learnable.

### Negative

- Existential `Runnable` collections require type erasure (`AnyRunnable<Input, Output>`). Most users won't hit this; advanced users will.
- The default `invoke` from `stream` (returning the last yielded value) is a convention that not all use cases will fit. Some Runnables explicitly override.
- Associated-type protocols are slightly less ergonomic in Swift than concrete generic types in some patterns.

### Mitigations

- Provide `AnyRunnable` and document when to reach for it.
- Document the "invoke = last value of stream" convention in the Runnable layer.
- Use `some Runnable<I, O>` opaque types liberally to avoid existentials at boundaries.

## Alternatives considered

### A. No composability primitive — each layer defines its own
Rejected. Every cross-cutting concern would be re-implemented per component. Decorators don't compose.

### B. Use Swift's `AsyncSequence` directly as the composition primitive
Rejected. `AsyncSequence` describes "thing that produces a stream" — it doesn't have a natural input. We need `Input → Output` (with optional streaming).

### C. Use closures only
Rejected. Closures are anonymous; they don't describe protocol-level capabilities (capabilities, configuration, named decorators). A protocol is the right granularity.

### D. Imitate Combine's `Publisher` shape
Rejected. Combine is Apple-only and conflicts with the platform-agnostic core decision (ADR 0002). Also, Combine's design is operator-heavy in ways that don't suit our streaming model.

## Independence note

The name `Runnable` is generic — Java has used it since 1995, and the pattern of "thing with an `invoke`/`run` method" exists across many languages and frameworks. Aria's `Runnable` is independently designed for Swift's protocol-with-associated-types and Swift Concurrency idioms. The protocol shape, semantics, default implementations, and decorator set are not derived from any other library.
