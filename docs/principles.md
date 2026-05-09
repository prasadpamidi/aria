# Architectural Principles

These are the rules Aria follows. Every design decision in the rest of these docs traces back to one or more of them. When in doubt, reach for these.

## 1. Layers, strictly

Aria has six layers (see [architecture.md](architecture.md)). A layer may only depend on layers *below* it. Higher layers compose lower-layer primitives; never the reverse.

**Why:** Strict layering lets you reason about the system bottom-up, test each layer in isolation, and swap implementations without cascading changes.

**How to apply:** If a foundation type seems to need a reference to the agent layer, the design is wrong. Refactor until the dependency points downward.

## 2. Protocols first, defaults included

Every meaningful component in Aria is a `protocol`, and every protocol ships with at least one **in-memory or trivial implementation in the core target**.

**Why:** Protocols give you swap points. In-memory defaults let users (and tests) get started without wiring up real infrastructure.

**How to apply:** When introducing a new capability, define the protocol first. If you cannot write a meaningful in-memory default, the protocol is probably too platform-specific to live in core.

## 3. Platform-agnostic core

The core target (`Aria`) builds and runs on Linux. It does not import `UIKit`, `AppKit`, `SwiftUI`, `FoundationModels`, `Combine`, `OSLog`, or any Darwin-only framework.

**Why:** Cross-platform potential, mechanical enforcement of clean boundaries, and the side benefit of fast Linux CI for unit tests.

**How to apply:** All Apple-platform code lives in `AriaApple`. If something cannot be expressed without an Apple framework, it does not belong in core.

See [platform-boundary.md](platform-boundary.md) for the full rule set.

## 4. Streaming is the default

Every output that *could* stream, *does* stream. `AsyncThrowingStream` is the universal output type. Non-streaming consumers collect the stream:

```swift
let result = try await Array(runnable.stream(input, options: .init()))
```

**Why:** Agents must stream tokens for UX. Two parallel APIs (`invoke` and `stream`) double the surface area and double the bugs. One code path, two ways to consume.

**How to apply:** When designing a new producer, start with the stream. Provide a convenience `invoke(...)` only when there's a clear ergonomic win.

## 5. Typed everything

Errors are `enum` cases. Events are `enum` cases. Configurations are `struct`s with explicit fields. Tool inputs and outputs are `Codable`. Public APIs do not return or accept untyped dictionaries except as user-supplied metadata.

**Why:** Types are the cheapest, most reliable form of documentation and the strongest tool against regression. Untyped data quietly rots.

**How to apply:** If you reach for `[String: Any]`, stop. Define a type. The exception is `metadata: [String: JSONValue]` on user-facing structs, where the user owns the keys.

## 6. Composition via Runnable

`Runnable<Input, Output>` is the unifying interface. Prompts, model calls, output parsers, retrievers, tools-as-callables, and entire agents all conform to `Runnable`. Composition is uniform.

**Why:** A single composability primitive lets you `pipe` anything together, share decorators (`withRetry`, `withTimeout`, `withObserver`), and treat agents as building blocks for larger agents.

**How to apply:** When designing a new component that maps input to output, ask "could this be a `Runnable`?" before introducing a new abstraction. The answer is usually yes.

## 7. Middleware over inheritance

Cross-cutting concerns — caching, retries, rate limiting, logging, RAG injection, fact extraction — are decorators on `Runnable` or `AgentMiddleware` hooks on the agent loop. Subclassing is not how Aria extends.

**Why:** Decorator composition is more flexible than inheritance, plays better with `Sendable`/value semantics, and avoids the deep-class-hierarchy problem.

**How to apply:** Whenever you want to add behavior "around" an existing component, write a wrapper or middleware. Do not modify the component itself.

## 8. Sendable everywhere

Every public type is `Sendable`. Strict concurrency is enabled. Actors guard mutable state. No shared `class` instances pretending to be safe.

**Why:** Aria runs in a concurrent world (background tasks, streaming, parallel tool calls). `Sendable` catches data-race bugs at compile time and incidentally catches a lot of "this won't port" issues for free.

**How to apply:** `Sendable` is the default. If you need mutable state, wrap it in an `actor`. If you must share something non-Sendable, isolate it behind an actor that owns it.

## 9. Errors are values, not exceptions

Aria uses `throws` for unrecoverable failures (network, IO, validation). For *expected* outcomes (a tool returning an error, the model refusing, max steps reached), Aria emits an event with a typed error case. Callers pattern-match.

**Why:** Distinguishing "expected outcome that callers must handle" from "unexpected failure that should propagate" makes flow control clear and avoids the trap of using exceptions as control flow.

**How to apply:** Reach for `throws` only when there is no reasonable way to continue. Otherwise, model the error as a typed event the caller can handle.

## 10. No global state, no singletons

Configuration, providers, tools, memory — all injected at the call site. There is no `Aria.shared`, no global registry, no implicit context.

**Why:** Global state makes testing painful, makes parallelism unsafe, and makes the system hard to reason about. Injection makes everything explicit.

**How to apply:** A new component takes its dependencies in `init`. If you find yourself reaching for a singleton, rethink the API.

## 11. Small foundation, additive everything else

The foundation (Layers 1–3) is a few hundred lines of Swift. Everything else — agent loop, graph orchestration, advanced memory patterns, observers — is **additive on top**, not a precondition.

**Why:** A small foundation is easy to learn, easy to maintain, and easy to keep correct. Optional layers stay optional; users pay only for what they use.

**How to apply:** When tempted to "just add this to the core," ask whether it could be a separate module or an additive protocol. Almost always, yes.

## 12. The library does not own observability

Aria exposes `Observer` and `AgentMiddleware` hooks. It does not build a tracing platform, a metrics SDK, or a cost dashboard. Applications wire those in.

**Why:** Observability is opinionated and platform-specific. Building it into the core couples Aria to choices that age fast.

**How to apply:** Provide hooks. Do not provide implementations beyond a default no-op.

---

## Anti-principles (things Aria explicitly rejects)

- **No reflection-driven configuration.** No "magic" string-keyed setup. Type-safe builders or nothing.
- **No untyped chains.** LangChain's runtime-typed chain composition is not the model. Aria uses associated types.
- **No vendor lock-in at the protocol level.** No `OpenAIProvider` shape leaking into core. Providers are providers.
- **No "everything is async" tax.** Pure functions stay pure. Only IO-bound work is async.
- **No backwards compatibility shims for unreleased code.** Until 1.0, breaking changes are expected and clearly marked.
