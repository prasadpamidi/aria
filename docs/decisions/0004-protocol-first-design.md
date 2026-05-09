# ADR 0004 — Protocol-first, with in-memory defaults in core

**Status:** Accepted
**Date:** 2026-05-09

## Context

Aria has many components that may be implemented in many ways:

- LLM providers (FoundationModels, MLX, Core ML, llama.cpp, custom)
- Embedders (NLEmbedding, Core ML, MLX, hosted)
- Vector stores (sqlite-vec, FAISS-like, in-memory)
- Chat history stores (SwiftData, file-backed, in-memory)
- Checkpointers (SwiftData, SQLite, in-memory)
- HTTP clients (URLSession, mock)
- Loggers (OSLog, swift-log, custom)

We need a strategy that:

- Keeps the core platform-agnostic (ADR 0002).
- Allows easy substitution for testing.
- Provides "just works" defaults for common cases.
- Doesn't force every consumer to implement infrastructure to get started.

## Decision

Every infrastructure-shaped component is defined as a `protocol` in core (`Aria`). Core ships a trivial in-memory or no-op implementation of each protocol. Real implementations live in platform modules (`AriaApple`) or in user code.

Examples:

- `LLMProvider` protocol in core; `MockLLMProvider` in `AriaTesting`; `FoundationModelsProvider` in `AriaApple`.
- `ChatHistory` protocol in core; `InMemoryChatHistory` in core; `SwiftDataChatHistory` in `AriaApple`.
- `Embedder` protocol in core; `HashEmbedder` (deterministic test embedder) in `AriaTesting`; `NLEmbeddingEmbedder` in `AriaApple`.
- `Checkpointer` protocol in core; `InMemoryCheckpointer` in core; `SwiftDataCheckpointer` in `AriaApple`.
- `VectorStore` protocol in core; `InMemoryVectorStore` in core; `SQLiteVecVectorStore` in `AriaApple`.

## Rationale

1. **Testability is a first-class concern.** Mock implementations let agent tests run without real models, real databases, or network access — and run on Linux.

2. **In-memory defaults are not throwaway.** They are real implementations used in tests, demos, and trivial production cases (e.g., a single-session conversation that doesn't need persistence).

3. **Protocols are Swift's natural extension point.** Concrete `class` hierarchies with subclassing are the wrong shape for swappable infrastructure.

4. **Dependency injection is the only sane strategy at scale.** Singletons and globals make testing painful, parallelism unsafe, and reasoning hard. Protocols + injection make every dependency explicit.

5. **The "platform module provides the real impl" pattern aligns with ADR 0002.** Apple-specific code is concentrated; cross-platform potential is preserved.

## Consequences

### Positive

- Tests are fast, deterministic, and run on Linux.
- Consumers can start small (in-memory) and graduate to durable storage by swapping one type.
- Apple-specific implementations are physically separated and easy to audit.
- Adding a new platform = add a new module that implements the protocols.

### Negative

- Every component requires designing a protocol *and* providing at least one default. More design upfront.
- Protocols with associated types (e.g., `Tool`) require type erasure in collections.
- Indirection through protocols adds a small runtime cost (vs. concrete types).

### Mitigations

- Take the protocol-design overhead seriously — a sloppy protocol is harder to evolve than a sloppy class. Get the shape right before shipping.
- Provide type-erased wrappers (`AnyTool`, `AnyRunnable`) where collections are needed.
- The runtime cost of protocol witness tables is negligible at the granularity Aria operates (per-step, per-tool-call). It is not a hot loop.

## Alternatives considered

### A. Concrete types with subclassing
Rejected. Inheritance hierarchies are inflexible for swappable infrastructure. Multiple-inheritance scenarios (a logger that's also an observer) get awkward. Protocols compose better.

### B. Closures and function pointers
Rejected for component-shaped concerns. Closures are unnamed and don't describe capabilities or lifecycle. A protocol with one method is no more complex and is much more discoverable.

### C. A central registry / service locator pattern
Rejected. Service locators are hidden globals. Explicit injection is harder upfront and easier forever after.

### D. Compile-time "platform" trait specialization
Rejected. The Linux-buildable rule (ADR 0002) requires a runtime swap point. Compile-time specialization conflicts with this.

## Implementation notes

Every protocol added to core must come with at least one trivial implementation in core. If you cannot write a meaningful in-memory or no-op default, the protocol is probably too platform-specific to live in core (and should move to `AriaApple`).
