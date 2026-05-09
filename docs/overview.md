# Overview

## What Aria is

Aria is a Swift library for building agent-driven applications that run on-device. It provides:

- A typed, composable runtime for tool-calling agents.
- A clean abstraction over local LLMs (Apple FoundationModels, MLX, llama.cpp, Core ML).
- Memory primitives for chat history, durable checkpoints, vector search, and long-term recall.
- A streaming-first event model that maps naturally to SwiftUI.
- An optional graph orchestration layer for branching, multi-step workflows.

Aria is **not** a wrapper around LangChain.js or any other framework. It is a native Swift library, designed from first principles for the constraints of on-device execution.

## Who Aria is for

- **iOS / macOS engineers** building features powered by on-device LLMs (Apple Intelligence, FoundationModels, custom MLX or Core ML models).
- Teams that need **agent loops with tool calling**, not just one-shot model inference.
- Teams that want **type safety, debuggability, and native performance** over framework breadth.
- Teams that may need to **port to other platforms eventually** but do not want to compromise the iOS experience to get there.

Aria is **not** for:

- Server-side LLM orchestration. Use LangChain, LangGraph, or similar.
- Cross-platform-first projects with no iOS investment. Pick a tool with day-one Android/web support.
- Projects that need hundreds of vendor integrations out of the box. Aria is intentionally narrow.

## The problem

Building agent-driven features on iOS today involves a tradeoff:

| Option | What you get | What you lose |
|---|---|---|
| Use LangChain.js in JavaScriptCore | Ecosystem breadth, hot-loadable agent logic | Bridge overhead, no native debugging, dependency surface that fights JSC |
| Hand-roll the agent loop per-feature | Full control, native performance | Reinventing primitives in every feature; no shared abstractions |
| Use a vendor-locked SDK (e.g., Apple Intelligence APIs directly) | Best Apple integration | No portability, no swap-in for MLX or llama.cpp, no agent orchestration above the model |

Aria fills the gap: a small, native, well-typed library that provides agent orchestration without locking you into a single model or platform.

## Goals

1. **Native Swift, native ergonomics.** Type-safe tools, `AsyncSequence` streaming, actor-based concurrency. Code that looks like Swift, not like a port.
2. **Provider-agnostic.** Swap FoundationModels for MLX or llama.cpp without changing agent code.
3. **Layered.** Use the foundation pieces independently. The agent loop is optional. The graph layer is optional. Memory protocols are optional.
4. **Platform-agnostic core.** The core target compiles on Linux. Apple-specific code lives in separate modules. The library can extend to other platforms without a rewrite.
5. **Streaming-first.** Every output is an `AsyncStream`. SwiftUI integration is the trivial case.
6. **Small surface area.** The foundation is roughly a dozen protocols. Easy to learn, easy to test, easy to maintain.

## Non-goals

1. **Not a framework for every LLM use case.** No vendor SDKs for OpenAI, Anthropic, etc. as a primary concern. Those exist; Aria does not duplicate them.
2. **Not a server orchestrator.** Long-running workflows, durable cluster state, and cloud deployment patterns are out of scope.
3. **Not a UI library.** Aria emits events. The application renders them.
4. **Not a tracing platform.** Aria exposes hooks for observability; building a LangSmith-equivalent is not its job.
5. **Not a polyglot library.** Aria is Swift. Bindings to other languages are explicitly out of scope.

## Comparison to alternatives

| | Aria | LangChain.js (in JSC) | Hand-rolled per-feature |
|---|---|---|---|
| Native iOS performance | Yes | Bridge tax | Yes |
| Type safety end-to-end | Yes | No | Yes |
| Composable across features | Yes | Yes | No |
| Cross-platform potential | Yes (core is portable) | Yes | No |
| Ecosystem of integrations | Small, focused | Large | None |
| Maintenance burden | Yours | Theirs | Yours, every feature |
| Hot-loadable agent logic | No | Yes | No |

Aria's bet: for native on-device agents, the cost of the JS bridge and the dependency surface of LangChain.js outweighs the ecosystem benefit, **provided** you keep the library small and focused on what matters for on-device use.

## Audience for this documentation

These docs assume Swift fluency, comfort with protocol-oriented design, and a working understanding of Swift Concurrency (actors, `AsyncSequence`, `Sendable`). They do not assume familiarity with LangChain or LangGraph; concepts borrowed from those frameworks are explained on first use.
