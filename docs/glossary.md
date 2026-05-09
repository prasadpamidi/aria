# Glossary

Definitions of terms used throughout Aria's documentation. Where a term has multiple common meanings, the meaning specific to Aria is given.

## A

**Agent** — A `Runnable<AgentInput, AgentEvent>` that orchestrates an `LLMProvider` and a set of `Tool`s in a tool-calling control loop. Lives in Layer 5.

**AgentEvent** — The output type of an `Agent`. An `enum` with cases for textDelta, toolCallRequested, toolExecutionEnd, finish, error, and others. Distinct from `ProviderEvent`.

**AgentMiddleware** — A protocol with `beforeRun`, `beforeStep`, `afterStep`, and `afterRun` hooks. Used to extend the agent loop without modifying it.

**AgentState** — The state the agent threads through its loop: thread id, accumulated messages, step count, scratchpad, pending tool calls.

**AnyTool** — Type-erased wrapper around a concrete `Tool`. Used in `[AnyTool]` collections passed to the agent.

**Aria** — This library. Also the name of the core target, which is platform-agnostic.

**AriaApple** — The platform module containing Apple-specific implementations (FoundationModels, MLX, SwiftData, sqlite-vec, NLEmbedding, OSLog).

**AriaTesting** — A target containing mocks and fixtures (e.g., `MockLLMProvider`, `HashEmbedder`).

**AriaTools** — A target containing cross-platform tool implementations.

## B

**Backoff** — A retry policy strategy (`constant` or `exponential`) used by `Runnable.withRetry`.

## C

**Channel** — In `StateGraph`, a strategy for merging `StateUpdate`s into state (`LastWriteWins`, `Append`, `Sum`, etc.).

**ChatHistory** — A protocol for storing per-thread conversation messages. In-memory default in core; SwiftData implementation in `AriaApple`.

**Checkpoint** — A snapshot of `AgentState` at a point in time. Identified by ULID, ordered by `createdAt`.

**Checkpointer** — A protocol for storing and retrieving `Checkpoint`s. Used for resume, time-travel, and human-in-the-loop interrupts.

**ContentPart** — One element of a `Message`'s content array. Cases include `text`, `image`, `audio`, `toolUse`, `toolResult`. Multimodal-first by design.

**Core** — Refers to the `Aria` target (platform-agnostic, Linux-buildable).

## D

**Deadline** — A `ContinuousClock.Instant` after which a run should be cancelled. Threaded through `RunOptions`.

## E

**Embedder** — A protocol that turns text into vector embeddings. Implementations: `NLEmbeddingEmbedder`, `CoreMLEmbedder`, `MLXEmbedder` (all in `AriaApple`).

## F

**FinishReason** — An `enum` describing why a model or agent run ended: `endTurn`, `maxTokens`, `toolUse`, `stopSequence`, `refusal`, `error`, `maxStepsReached`.

**FoundationModels** — Apple's framework for on-device large language models, introduced in iOS 26 / macOS 26. Aria's `FoundationModelsProvider` lives in `AriaApple`.

## G

**GenerationOptions** — Per-call model parameters: temperature, max tokens, stop sequences, response format, seed, and a provider-specific escape hatch.

## H

**HistoryPolicy** — A strategy for selecting which messages from `ChatHistory` to send to the model. Options: `keepAll`, `lastN`, `tokenWindow`, `summarize`, `windowedWithSummary`, `custom`.

**Hooks** — `AgentMiddleware`'s injection points (`beforeRun`, `beforeStep`, `afterStep`, `afterRun`). Compare to "middleware" in web frameworks.

**HTTPClient** — A protocol for making HTTP requests. Aria does not import `URLSession` in core; consumers inject an implementation.

## I

**In-memory default** — A trivial implementation of an infrastructure protocol (e.g., `InMemoryChatHistory`, `InMemoryVectorStore`) that ships in core. Useful for tests and trivial cases.

## J

**JSC** — JavaScriptCore. Apple's JavaScript engine, considered as an alternative runtime in [ADR 0001](decisions/0001-native-swift-vs-js.md). Not used by Aria.

**JSONSchema** — A structured Swift `enum` that represents a JSON Schema definition. Used for tool input/output schemas.

**JSONValue** — A structured Swift `enum` that represents an arbitrary JSON value. Used for tool arguments and metadata.

## L

**LLMProvider** — The protocol defining the model boundary. Implementations stream `ProviderEvent`s in response to messages and tool definitions.

## M

**Memory** — In Aria, a collective term for `ChatHistory`, `Checkpointer`, `VectorStore`, and `MemoryStore`. Each addresses a different concern.

**MemoryStore** — A high-level "remember/recall" protocol that composes `Embedder` + `VectorStore` + namespacing.

**Message** — A unit of conversation. Has a role (`system`, `user`, `assistant`, `tool`), content, optional tool calls, and optional tool call id.

**Middleware** — See `AgentMiddleware`.

**MLX** — Apple's machine learning framework optimized for Apple Silicon. Aria's `MLXProvider` lives in `AriaApple`.

## N

**Namespace** — A `[String]` path used by `MemoryStore` to scope memories (e.g., `["user_42", "preferences"]`).

**NLEmbedding** — Apple's built-in text embedding model in the NaturalLanguage framework. Used by `NLEmbeddingEmbedder`.

## O

**Observer** — A protocol with `runStart`, `runEnd`, `runError`, `chunk` callbacks. Used to attach tracing or metrics to `Runnable` execution.

## P

**Pipe** — A `Runnable` combinator: `a.pipe(b)` produces a new Runnable that calls `a` then feeds its output to `b`.

**Platform boundary** — The rule that `Aria` is platform-agnostic and Apple-specific code lives in `AriaApple`. Enforced by a Linux build job in CI. See [docs/platform-boundary.md](platform-boundary.md).

**Protocol** — In Swift, an abstract interface. Aria uses protocols extensively for swappable infrastructure (providers, memory, tools).

**Provider** — Short for `LLMProvider`. Sometimes also used for `Embedder` or other infrastructure providers; context disambiguates.

**ProviderCapabilities** — A struct describing what a given `LLMProvider` supports: streaming, tool use, parallel tools, vision, audio, structured output, system prompt, max context tokens.

**ProviderEvent** — The output type of an `LLMProvider`'s stream. Cases: `messageStart`, `textDelta`, `toolCallStart`, `toolCallDelta`, `toolCallEnd`, `messageStop`, `usage`.

## R

**RAG** — Retrieval-Augmented Generation. In Aria, implemented as middleware that calls `MemoryStore.recall` and injects context before the model call.

**ReAct** — A common agent pattern: Reason about the situation, Act (call a tool), observe the result, repeat. Aria's tool-calling agent follows this pattern.

**RunOptions** — Per-invocation configuration threaded through every `Runnable`. Carries run id, parent run id, tags, metadata, observers, deadline, cancellation token.

**Runnable** — The composability primitive: `protocol Runnable<Input, Output>: Sendable` with `invoke` and `stream`. See [layers/02-runnable.md](layers/02-runnable.md).

## S

**Sample app** — A demonstration application consuming Aria. Lives in `Examples/`.

**Sendable** — A Swift protocol marking types safe to share across concurrency domains. Required throughout Aria.

**Skip** — A toolchain (skip.tools) that transpiles Swift to Kotlin/Compose for Android. Discussed in [overview.md](overview.md) as a future possibility, not a current dependency.

**StateGraph** — Aria's optional graph orchestration layer. See [layers/06-stategraph.md](layers/06-stategraph.md).

**StateUpdate** — A partial update to graph state, returned by a `StateGraph` node. Channels merge updates into state.

**Stream** — In Aria, an `AsyncThrowingStream<Output, Error>`. The canonical output shape for `Runnable`s.

**Superstep** — A unit of `StateGraph` execution: all ready nodes run concurrently, then their updates merge.

## T

**Thread** — A conversation identity. `threadId` keys `ChatHistory` and `Checkpointer` storage.

**Tokenizer** — A protocol for counting tokens in text or messages. Used by `HistoryPolicy.tokenWindow`.

**Tool** — A protocol with associated `Input` and `Output` Codable types and a `call` method. Defines a function the model can invoke.

**ToolCall** — A request from the model to invoke a tool, with `id`, `name`, and `arguments`.

**ToolContext** — A small bag of context passed to `Tool.call`: run id, cancellation token, metadata.

**ToolDefinition** — The serializable description of a tool sent to the model: name, description, input schema, optional output schema.

**Tool calling** — The pattern where the model emits structured tool calls in its output, the runtime executes them, and feeds results back. Aria's agent loop implements this.

## U

**ULID** — Universally unique, lexicographically sortable identifier. Used for `Checkpoint.id`.

**Usage** — Token counts (input, output, cache read, cache create) reported by some providers. Surfaced as `ProviderEvent.usage`.

## V

**VectorItem** — A vector + content + metadata + id, stored in a `VectorStore`.

**VectorMatch** — A search result from `VectorStore.search`: id, score, content, metadata.

**VectorStore** — A protocol for storing and similarity-searching over vectors. In-memory default in core; sqlite-vec implementation in `AriaApple`.
