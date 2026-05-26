# Aria

[![CI](https://github.com/prasadpamidi/aria/actions/workflows/ci.yml/badge.svg)](https://github.com/prasadpamidi/aria/actions/workflows/ci.yml)
[![Swift](https://img.shields.io/badge/Swift-6.1+-F05138?logo=swift&logoColor=white)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%2018%2B%20%7C%20macOS%2015%2B%20%7C%20Linux-lightgrey)](https://github.com/prasadpamidi/aria/blob/main/Package.swift)
[![SPM compatible](https://img.shields.io/badge/SPM-compatible-brightgreen?logo=swift)](https://github.com/prasadpamidi/aria/blob/main/Package.swift)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue)](LICENSE)
[![Latest release](https://img.shields.io/github/v/release/prasadpamidi/aria?include_prereleases&sort=semver&label=latest)](https://github.com/prasadpamidi/aria/releases)

**Composable on-device + remote agent runtime for Apple platforms.**

Aria is a Swift library for building agent-driven applications. The
default path runs on-device using Apple's FoundationModels, MLX, or
Core ML; the same `Agent` and `WorkflowKit` surfaces also drive
remote OpenAI / Anthropic / Gemini / OpenAI-compatible providers
(see [Remote-LLM orchestration](#remote-llm-orchestration) below for
the current limitations). Aria provides a tool-calling agent
runtime, type-safe abstractions over LLMs, memory primitives, a
workflow runtime with native + JS-plugin capabilities, an Anthropic-
style skill system, and an optional graph orchestration layer.

The core is platform-agnostic and builds on Linux. Apple-specific
implementations live in `AriaApple`.

> **Status:** Layers 1–6 are implemented and tested on iOS 26 / macOS 26 / Linux. Headline features:
>
> - Tool-calling **Agent** with streaming events, the full middleware stack (history persistence, windowing, summarization, RAG retrieval, automatic fact extraction), and **provider-agnostic** structured-output `respond(_:as:)` that works against FoundationModels and any cloud `LLMProvider`.
> - **WorkflowKit** runtime — Codable workflow model, GRDB persistence, compile-to-`StateGraph` engine, capability broker for native iOS frameworks, JS plugin steps, per-step server-LLM routing, MCP integration, skill resolution. See [`docs/workflowkit.md`](docs/workflowkit.md).
> - **AgentKit** runtime — Codable `AgentDefinition`, file-per-row JSON store, capability-to-tool bridging, `ProposeTool` + `AgentApprovalSink` for human-in-the-loop side-effects, checkpoint middleware, in-loop validator with retry cap. Apple-only; injects the host's MCP / workflow / plugin / skill tool surfaces via closures. See [`docs/agentkit.md`](docs/agentkit.md).
> - **Skills** — Anthropic-style instruction bundles (`SKILL.md` frontmatter + body) with `SkillProvider`, on-demand `load_skill` tool, per-thread / per-workflow overrides via `SkillOverridesStore`. See [`docs/skills.md`](docs/skills.md).
> - **JS plugin tools** — sandboxed `JSContext`-based runtime (`AriaToolsJS`) that loads `.aria-tool` bundles. Capabilities (HTTP, JSON, clipboard, share, notify, storage) are gated by per-bundle manifest declarations and enforced at bridge-construction time. See [`docs/plugins.md`](docs/plugins.md).
> - **Native capabilities** — Keychain-backed secrets, Calendar / Reminders, HealthKit, CoreLocation, EventKit, Files, Clipboard, Share, Notifications, HTTP, Focus, Shortcuts. Wrapped behind a `CapabilityBroker` that enforces per-plugin grants.
> - **StateGraph** with conditional edges, parallel branches + reducers, agent-as-node helpers, and resumable runs via the `Checkpointer`.
> - **Memory layer** with persistent SQLite chat history + vector store (`GRDBChatHistory`, `GRDBVectorStore`), `NLEmbeddingEmbedder` for on-device embeddings, and `HistoryRetentionPolicy` for bounded disk growth.
> - **Long-thread strategies that just compose**: `HistoryWindowMiddleware` (turns + token caps), `HistorySummarizationMiddleware` (compress older portion into a summary system message), `FactExtractionMiddleware` (auto-mine durable user facts into `MemoryStore`).
> - **OpenTelemetry-compatible observability** via `swift-distributed-tracing` + `swift-metrics`. Spans use OTel GenAI semantic conventions; backends like Phoenix / Honeycomb auto-render the runs.
> - **Session recording + replay** via `SessionRecorder` + `SessionReplayer` (in `AriaTesting`). Capture a run as a `SessionBundle` JSON, ship it anywhere, replay against a fresh agent for regression tests, prompt experiments, or debugging.

---

## Why

- **Native.** No JavaScriptCore bridge, no embedded JS runtime. Native Swift, native debugging, native performance.
- **Type-safe end-to-end.** Tools have typed input and output. Events are enums. No `[String: Any]`.
- **Streaming-first.** `AsyncThrowingStream` is the universal output shape; SwiftUI integration is trivial.
- **Provider-agnostic.** Swap FoundationModels for MLX or Core ML without touching agent code.
- **Cross-platform-ready.** Core compiles on Linux. Future Android support via Skip, KMP wrapper, or the Swift Android toolchain is preserved at near-zero cost.

## Architecture in one diagram

```
                ┌────────────────────────────────────────────────────────┐
                │              HOST APP  (avyra, niora, your app)        │
                │   Wires tool sources + LLM routing into the runtimes,  │
                │   ships UI, owns content (workflows, agents, skills)   │
                └──┬───────────────────────────────┬─────────────────────┘
                   │                               │
                   ▼                               ▼
        ┌──────────────────────┐        ┌──────────────────────────┐
        │     WorkflowKit      │        │         AgentKit         │
        │ ── recipes you write │        │ ── goals you delegate    │
        │  • Codable Workflow  │        │  • Codable AgentDefinition│
        │  • CapabilityBroker  │        │  • AgentRuntime + compiler│
        │  • Step compiler →   │        │  • ProposeTool + approval │
        │    StateGraph        │        │  • Checkpoint middleware  │
        │  • GRDB store        │        │  • File-JSON stores       │
        └──────────┬───────────┘        └────────────┬──────────────┘
                   │                                  │
                   └─────────────┬────────────────────┘
                                 ▼
        ┌────────────────────────────────────────────────────────┐
        │                       Aria (core)                      │
        │  Layer 6:  StateGraph     (optional graphs)            │
        │  Layer 5:  Agent          (tool-calling loop)          │
        │  Layer 4:  Memory         (history, vectors)           │
        │  Layer 3:  Providers      (LLM, Tool, Embedder)        │
        │  Layer 2:  Runnable       (composability)              │
        │  Layer 1:  Foundation     (data model)                 │
        └────────────────────────────────────────────────────────┘
                                 ▲
                                 │ binds to platform-specific impls
        ┌────────────────────────┴───────────────────────────────┐
        │  AriaApple   AriaMLX*   AriaVoice   AriaVoiceKokoro*   │
        │  ──────────  ────────   ─────────   ─────────────────  │
        │  FoundationModels      Speech + AVSpeech    Kokoro 82M │
        │  GRDB memory           STT/TTS              TTS        │
        │                                  (* = SPM-trait-gated) │
        └────────────────────────────────────────────────────────┘
```

**Mental model:** the bottom (`Aria` core) is platform-agnostic
and Linux-buildable; the platform tier binds it to Apple APIs;
**WorkflowKit + AgentKit** are two peer runtimes sitting above
that — `WorkflowKit` runs *recipes you wrote*, `AgentKit` runs
*goals you delegated*. Both compose Aria's `Agent` loop +
middleware; both call into `CapabilityBroker` for native side
effects. Host apps pick either or both.

Within Aria, a layer depends only on layers below. See
[`docs/architecture.md`](docs/architecture.md).

## Package layout

```
Sources/
├── Aria/                Layers 1–6, platform-agnostic (Linux-buildable)
├── AriaTesting/         Mocks, fixtures, SessionReplayer
├── AriaApple/           FoundationModels + GRDB-backed memory (Apple-only)
├── AriaTools/           Cross-platform tool implementations (HTTP, JSON, Regex, …)
├── AriaToolsJS/         JavaScriptCore-sandboxed user plugin runtime
├── AriaVoice/           Speech.framework STT + AVSpeechSynthesizer TTS
├── AriaMLX/             MLX-backed LLMProvider          (opt-in via `MLX` trait)
├── AriaVoiceKokoro/     On-device Kokoro 82M TTS        (opt-in via `VoiceKokoro` trait)
├── WorkflowKit/         Workflow runtime + CapabilityBroker + skills + plugin steps
├── AgentKit/            Agent runtime + AgentDefinition + ProposeTool + checkpoints
└── AriaCLI/             Demo CLI — records a run, prints the bundle, replays it
```

WorkflowKit and AgentKit are independent of each other; either
can be used standalone. The avyra app ships both — workflows for
deterministic tile-tap tasks, agents for delegated goals.

## Traits — opt-in heavy dependencies

Aria exposes two SPM traits (SE-0480, Swift 6.1+) for code paths
with large transitive dependency graphs:

| Trait | Pulls in | Enables |
| --- | --- | --- |
| `MLX` | `mlx-swift-lm`, `swift-huggingface-mlx`, `swift-transformers-mlx` | `AriaMLX` — on-device LLM via MLX |
| `VoiceKokoro` | `kokoro-ios`, `mlx-swift`, `MLXUtilsLibrary` | `AriaVoiceKokoro` — Kokoro 82M TTS |

Neither trait is on by default. SwiftPM still resolves the
dependency packages (they appear in `Package.resolved`), but the
target sources compile to empty unless the matching trait is
enabled — so the heavy build / link cost only kicks in when a
consumer actually uses the feature.

Enable from a consumer's `Package.swift`:

```swift
.package(
    url: "https://github.com/prasadpamidi/aria.git",
    from: "0.1.0",
    traits: ["MLX", "VoiceKokoro"]
)
```

Or in an Xcode project's "Add Package Dependency" dialog — tick
the trait checkboxes when adding Aria.

## Building the SDK

The Fastfile wraps every trait combination:

```bash
bundle exec fastlane package_build              # default traits
bundle exec fastlane package_build_mlx          # --traits MLX
bundle exec fastlane package_build_voice_kokoro # --traits VoiceKokoro
bundle exec fastlane package_build_all          # --traits MLX,VoiceKokoro
bundle exec fastlane package_tests              # swift test
bundle exec fastlane quality                    # swiftformat + swiftlint
```

## Quick start

```swift
import Aria
import AriaApple

let storage = try GRDBStorage()
let timeKit = registerFoundationModelsTool(CurrentTimeTool())

let agent = Agent(config: AgentConfig(
    provider: FoundationModelsProvider(typedTools: [timeKit.factory]),
    tools: [timeKit.anyTool],
    systemPrompt: "You are a helpful assistant.",
    threadId: "main",
    middleware: [HistoryMiddleware(history: storage.chatHistory)]
))

for try await event in agent.stream(.message(.user("What's the time in Tokyo?"))) {
    switch event {
    case let .textDelta(chunk): print(chunk, terminator: "")
    case let .toolCallRequested(call): print("[calling \(call.name)]")
    case .finish: print("\n[done]")
    default: break
    }
}
```

### Production-grade middleware stack

Long-running threads need bounded context, a summary of older turns, and a
durable memory layer. Compose the built-in middlewares — order matters
(load → summarize → window → recall → extract):

```swift
import Aria
import AriaApple

let storage = try GRDBStorage()
let embedder = NLEmbeddingEmbedder()!
let memory = DefaultMemoryStore(
    embedder: embedder,
    store: storage.vectorStore(dimensions: embedder.dimensions)
)

let agent = Agent(config: AgentConfig(
    provider: FoundationModelsProvider(),
    tools: [],
    systemPrompt: "You are a helpful assistant.",
    threadId: "main",
    middleware: [
        // 1. Persistent transcript loaded from GRDB on beforeRun
        HistoryMiddleware(history: storage.chatHistory),
        // 2. Compress the older portion into a summary system message
        //    once the thread grows past 24 non-system turns
        HistorySummarizationMiddleware(
            triggerAfterTurns: 24,
            keepRecentTurns: 6,
            summarizer: { messages in
                // Typically a cheap LLM call (gpt-4o-mini, on-device 3B)
                try await mySummarizer.summarize(messages)
            }
        ),
        // 3. Hard window so the provider sees a bounded transcript
        HistoryWindowMiddleware(maxTurns: 16, maxTokens: 4000),
        // 4. Recall top-K user memories for the latest message
        RAGMiddleware(memoryStore: memory, namespace: ["user", userId], topK: 5),
        // 5. Auto-mine durable facts from each user turn (background)
        FactExtractionMiddleware(
            memory: memory,
            namespace: ["user", userId],
            extractor: { message in
                try await myExtractor.facts(from: message)
            }
        ),
    ]
))

// Bound disk growth across all threads — run on launch / nightly.
try await HistoryRetentionPolicy(maxThreadAgeDays: 90, maxThreadCount: 20)
    .enforce(on: storage.chatHistory)
```

### Structured output against any provider

`Agent.respond(_:as:)` works against FoundationModels **and** any cloud
`LLMProvider` — the agent layer derives the schema from the `Generable`
type and injects it as `ResponseFormat.schema(...)` (or `.rawSchema(...)`
for opaque JSON Schemas that don't round-trip through Aria's typed
`JSONSchema`):

```swift
@Generable
struct ActivitySuggestion {
    var title: String
    var summary: String
    var steps: [String]
}

for try await event in agent.respond(.message(.user("Suggest something fun")),
                                     as: ActivitySuggestion.self) {
    switch event {
    case .partial(let snapshot): render(snapshot)  // optionals fill in over time
    case .finish(let suggestion): commit(suggestion)
    case .toolCallExecuted: break
    }
}
```

A complete record + replay loop in 20 lines (cross-platform, no Apple deps):

```swift
import Aria
import AriaTesting

// 1. Record an agent run
let recorder = SessionRecorder()
let recording = RecordingMiddleware(recorder: recorder)
let provider = MockLLMProvider(scenes: [.text("hello")])
let agent = Agent(config: AgentConfig(
    provider: provider, tools: [], threadId: "demo",
    middleware: [recording]
))
for try await _ in agent.stream(.message(.user("hi"))) {}

// 2. Bundle it (Codable, ship anywhere)
let bundle = await recorder.bundle()
let json = try JSONEncoder().encode(bundle)

// 3. Replay against a fresh agent
let replay = SessionReplayer.mockProvider(from: bundle.agent!)
let replayedAgent = Agent(config: AgentConfig(provider: replay, tools: [], threadId: "replay"))
```

Run the same flow as a CLI demo:

```bash
swift run AriaCLI    # records, prints the JSON bundle, replays it
```

## Remote-LLM orchestration

Aria's `Agent` and `WorkflowKit` runtime accept any `LLMProvider`
conformer — the on-device FoundationModels / MLX providers are the
default path, but cloud OpenAI / Anthropic / Gemini /
OpenAI-compatible endpoints work the same way. A workflow step
declares `serverProviderID: "openai-prod"` (or leaves it `nil` for
the default provider) and the runtime resolves the right transport
at compile time.

What works today:

- Streaming text and structured-output `respond(_:as:)` against any
  `LLMProvider` — `FoundationModelsProvider`, `MLXProvider`, and
  the server-LLM resolver path in `WorkflowKit` cover the same
  agent + middleware stack.
- Per-workflow-step routing via `ServerLLMProviderResolver` so a
  workflow can mix on-device steps with cloud steps in one graph.
- Credential resolution via `CredentialStore` so each server
  provider's API key + auth headers come from Keychain, not config
  files.

Known limitations / pending work:

- **Tool-calling against server LLMs** is wired end-to-end for
  OpenAI-compatible providers but the typed-tool surface still
  routes most cleanly through FoundationModels' `@Generable` path
  on Apple platforms. Cloud-provider tool calls go through the
  same `Agent` runtime but the JSON-schema → `@Generable`
  round-trip is opaquer; complex multi-tool runs may need a
  schema-level adapter per provider.
- **Streaming semantics** vary by provider (OpenAI's chunked
  `data:` SSE vs Anthropic's event-typed SSE vs Gemini's protobuf
  responses). Aria normalizes to a single `ProviderEvent` stream;
  edge cases like mid-stream tool calls in newer Anthropic
  `tool_use` events are still being hardened.
- **MCP servers** are integrated as a tool surface but rate
  limiting / retry behaviour across MCP transports (`stdio`,
  `http`) is a per-server contract that callers wire themselves.
- **Provider error normalization** still leaks transport-specific
  details in some failure modes. Treat `ProviderError` as a hint,
  not a stable contract.

See [`docs/workflowkit.md`](docs/workflowkit.md) for the routing /
resolver shape and a worked OpenAI + on-device hybrid example.

## Build and test

```bash
swift build                                # build the package (default traits)
swift build --traits MLX,VoiceKokoro       # build with the heavy traits
swift test                                 # run all tests
swift test --filter AriaTests              # core tests (Linux-safe)
swift run AriaCLI                          # run the CLI demo
```

### Local setup (one-time)

```bash
brew bundle                   # swiftformat, swiftlint
bundle install                # fastlane
./scripts/install-hooks.sh    # pre-commit hook (lint + format gate)
```

### Fastlane

Routine work goes through Fastlane lanes:

```bash
bundle exec fastlane package_build         # swift build (default traits)
bundle exec fastlane package_build_all     # all trait variants
bundle exec fastlane package_tests         # swift test
bundle exec fastlane cli_demo              # swift run AriaCLI
bundle exec fastlane lint                  # SwiftLint
bundle exec fastlane format                # SwiftFormat (in place)
bundle exec fastlane quality               # format --lint + lint
bundle exec fastlane quality fix:true      # auto-fix both
```

See [`AGENTS.md`](AGENTS.md) for the full lane reference.

## Documentation

- [`docs/overview.md`](docs/overview.md) — what Aria is, who it's for
- [`docs/principles.md`](docs/principles.md) — architectural principles
- [`docs/architecture.md`](docs/architecture.md) — layered design and module layout
- [`docs/traits.md`](docs/traits.md) — SPM traits (MLX, VoiceKokoro)
- [`docs/workflowkit.md`](docs/workflowkit.md) — workflow runtime, capabilities, server-LLM routing
- [`docs/agentkit.md`](docs/agentkit.md) — agent runtime, definitions, propose-then-host-executes
- [`docs/skills.md`](docs/skills.md) — Anthropic-style skill bundles
- [`docs/plugins.md`](docs/plugins.md) — JS plugin tools (`.aria-tool` runtime)
- [`docs/platform-boundary.md`](docs/platform-boundary.md) — cross-platform discipline
- [`docs/observability.md`](docs/observability.md) — OTel tracing/metrics + session recording / replay
- [`docs/layers/`](docs/layers/) — per-layer specs
- [`docs/decisions/`](docs/decisions/) — architecture decision records
- [`docs/glossary.md`](docs/glossary.md) — terminology

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) and [`AGENTS.md`](AGENTS.md). Aria is a clean-room implementation; please read [`NOTICE.md`](NOTICE.md) before contributing.

## License

[MIT](LICENSE)
