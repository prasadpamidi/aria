# Glossary

Definitions of terms used throughout Aria's documentation. Where a term has multiple common meanings, the meaning specific to Aria is given.

## A

**Agent** — A `Runnable<AgentInput, AgentEvent>` that orchestrates an `LLMProvider` and a set of `Tool`s in a tool-calling control loop. Lives in Layer 5.

**AgentApprovalSink** — Internal hand-off used by the propose-then-host-executes pattern. `ProposeTool` records the proposal into the sink and returns "stop and wait"; `AgentRuntime` reads the sink between steps to drive the human-in-the-loop pause.

**AgentCatalog** — In-memory registry of curated agent entries the host populates at boot. The gallery / catalogue UI reads from this; users Run or Remix entries into their own `AgentStore`. Mirrors `WorkflowCatalog` in role. Lives in `AgentKit`.

**AgentCompiler** — Lowers an `AgentDefinition` to a concrete `Aria.Agent`. Resolves capabilities → tools (via `CapabilityToolKitBuilder`), invokes the host's `AgentExtraToolsProvider` for MCP / workflow / plugin / skill tools, builds the middleware chain, picks the LLM provider, and stamps the date anchor onto the system prompt. Part of `AgentKit`.

**AgentDefinition** — The Codable, persistent description of an agent: name, system prompt, tool allowlists, approval policy, model routing, suggested actions. The "what an agent is," stored in `AgentStore`. Mirrors `Workflow` in shape but describes a goal-driven loop instead of a step recipe.

**AgentEvent** — The output type of an `Agent`. An `enum` with cases for textDelta, toolCallRequested, toolExecutionEnd, finish, error, and others. Distinct from `ProviderEvent` and from `AgentRunEvent` (which is the UI-facing wrapper emitted by `AgentRuntime`).

**AgentExtraToolsProvider** — Closure the host injects into `AgentRuntime.boot` to supply MCP / workflow-as-tool / plugin / `load_skill` tool kits per agent. AgentKit knows nothing about these sources; the host wires them.

**AgentKit** — The reusable agents target sitting alongside `WorkflowKit`. Apple-only runtime that compiles `AgentDefinition`s into `Aria.Agent` instances, drives them via streaming events, and provides the human-in-the-loop primitives (`ProposeTool`, `AgentApprovalSink`). See [`agentkit.md`](agentkit.md).

**AgentMiddleware** — A protocol with `beforeRun`, `beforeStep`, `afterStep`, and `afterRun` hooks. Used to extend the agent loop without modifying it.

**AgentPersona** — Discovery-time grouping for catalogue entries: `yourDay`, `healthAndBody`, `communication`, `capture`, `focus`, `research`. Drives the gallery's filter pills and section headers.

**AgentProposal** — A structured side-effect the agent recorded via `ProposeTool` and is awaiting approval for. Carries `kind` ("send_email", "create_event", "schedule_notification", …) plus arguments. The host's responsibility to execute on `.approve`.

**AgentProviderFactory** — Closure the host injects into `AgentRuntime.boot` to pick an `LLMProvider` per `AgentDefinition`. Typically: server LLM if pinned, else MLX if pinned, else FoundationModels.

**AgentRunEvent** — Streaming event type emitted by `AgentRuntime.runStreaming` / `resumeStreaming`. Cases include `runStarted`, `stepStart`, `textDelta`, `toolCallRequested`, `awaitingApproval`, `checkpointSaved`, `finished`, `failed`. UI-facing; wraps the lower-level `AgentEvent` from `Aria.Agent`.

**AgentRunRecord** — Per-run persistent record stored in `AgentRunStore`. Tracks status (`running` | `paused` | `awaitingApproval` | `completed` | `failed`), current step, last checkpoint id, pending proposal, summaries, timestamps. Survives app restart so the active-runs UI and the deep-link resume path can recover state.

**AgentRunStore** — File-per-row JSON store for `AgentRunRecord`s. Sibling of `AgentStore`.

**AgentRuntime** — `@MainActor` singleton-ish actor that owns the active agent runs. Boots once at app launch with the host's storage + closures; exposes `runStreaming(agentID:input:threadId:)` and `resumeStreaming(runID:approval:)`. Part of `AgentKit`.

**AgentState** — The state the agent threads through its loop: thread id, accumulated messages, step count, scratchpad, pending tool calls.

**AgentStore** — File-per-row JSON store for `AgentDefinition`s. Sibling of `AgentRunStore`. Supports CRUD + `clone(from:)` (sets `parentAgentID`).

**AgentTrigger** — Discovery hint on an `AgentDefinition` for surfacing in UI (`.suggested`, `.scheduled`, `.manual`). The runtime never reads these; they're for catalogue + home-rail logic.

**AnyTool** — Type-erased wrapper around a concrete `Tool`. Used in `[AnyTool]` collections passed to the agent.

**ApprovalPolicy** — Field on `AgentDefinition`. `.autonomous` (no approval gates) or `.proposeThenConfirm(actions:)` (side-effecting tools in the list must be proposed via `ProposeTool` and host-executed on approval).

**Aria** — This library. Also the name of the core target, which is platform-agnostic.

**AriaApple** — The platform module containing Apple-specific implementations (FoundationModels, GRDB-backed memory, NLEmbedding).

**AriaTesting** — A target containing mocks and fixtures (e.g., `MockLLMProvider`, `HashEmbedder`, `SessionReplayer`).

**AriaTools** — A target containing cross-platform tool implementations (HTTP, JSON, Regex, Calculator).

## B

**Backoff** — A retry policy strategy (`constant` or `exponential`) used by `Runnable.withRetry`.

## C

**CapabilityBroker** — `WorkflowKit`'s actor that enforces per-caller grants on every native capability call (Calendar, Reminders, HealthKit, etc.). Both `WorkflowKit` step execution and `AgentKit`'s capability tools go through the same broker.

**CapabilityCatalog** — Per-method registry inside `AgentKit/Engine/CapabilityCatalog.swift` describing the JSON arg-hint, side-effect flag, and summary the agent sees for each `(CapabilityID, method)` pair. Drives the `argHint` text that goes into tool descriptions.

**CapabilityToolKitBuilder** — Bridges `CapabilityID`s to `FoundationModelsToolKit`s the agent loop can call. Builds one kit per allowed `(capability, method)` pair, forwarding JSON args to `CapabilityBroker.call(...)`. Lives in `AgentKit`.

**Channel** — In `StateGraph`, a strategy for merging `StateUpdate`s into state (`LastWriteWins`, `Append`, `Sum`, etc.).

**ChatHistory** — A protocol for storing per-thread conversation messages. In-memory default in core; GRDB-backed implementation in `AriaApple`.

**Checkpoint** — A snapshot of `AgentState` at a point in time. Identified by ULID, ordered by `createdAt`.

**Checkpointer** — A protocol for storing and retrieving `Checkpoint`s. Used for resume, time-travel, and human-in-the-loop interrupts.

**CheckpointMiddleware** — `AgentKit` middleware that fires `afterStep`, encodes the full `AgentState` to JSON, and writes it through the `Checkpointer` keyed by `threadId`. Also yields a `.checkpointSaved` `AgentRunEvent` so the UI can show step progress. (Known limitation: `AgentRuntime.resumeStreaming` does not yet restore scratchpad / step count from the checkpoint; see [`agentkit.md`](agentkit.md) for the workaround.)

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

**ProposeTool** — The single tool an `AgentKit` agent gets in place of side-effecting capabilities under a `.proposeThenConfirm(actions:)` policy. Records a structured `AgentProposal` into `AgentApprovalSink` and returns "stop and wait." Validates payloads per-kind with a retry cap so a malformed proposal can't loop forever. Apple-only.

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
