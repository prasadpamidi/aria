<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Assets/aria-lockup-dark.svg">
    <img src="Assets/aria-lockup-light.svg" alt="Aria" height="64">
  </picture>
</p>

[![CI](https://github.com/prasadpamidi/aria/actions/workflows/ci.yml/badge.svg)](https://github.com/prasadpamidi/aria/actions/workflows/ci.yml)
[![Swift](https://img.shields.io/badge/Swift-6.1+-F05138?logo=swift&logoColor=white)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%2018%2B%20%7C%20macOS%2015%2B%20%7C%20Linux-lightgrey)](https://github.com/prasadpamidi/aria/blob/main/Package.swift)
[![SPM compatible](https://img.shields.io/badge/SPM-compatible-brightgreen?logo=swift)](https://github.com/prasadpamidi/aria/blob/main/Package.swift)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue)](LICENSE)
[![Latest release](https://img.shields.io/github/v/release/prasadpamidi/aria?include_prereleases&sort=semver&label=latest)](https://github.com/prasadpamidi/aria/releases)

**Agents that run on the user's device, and survive contact with a 4,096-token window.**

Aria is a Swift library for building agent-driven apps on Apple platforms. The
default path runs on-device via FoundationModels or MLX; the same `Agent` surface
drives OpenAI / Anthropic / Gemini when you need to reach further.

```swift
let agent = Agent(config: AgentConfig(
    provider: FoundationModelsProvider(typedTools: [weatherTool]),
    tools: [weatherTool.anyTool],
    systemPrompt: "You are a concise assistant."
))

for try await event in agent.stream(.message(.user("What's the weather in Berlin?"))) {
    if case let .textDelta(text) = event { print(text, terminator: "") }
}
```

That much you could write against Apple's API directly. What Aria adds is
everything that goes wrong afterwards.

## The number

Same six tasks, same on-device model, same prompts. One arm is a bare
`FoundationModelsProvider`; the other adds a context assembler and a per-turn
tool budget. Three trials of the corpus each:

| tool surface | bare provider | with Aria's context layer |
|---|---|---|
| 12 tools — fits the window | **83%** | 78% |
| 50 tools — does not fit | **0%** (every turn refused) | **83%** |

Read the first row honestly: under about twenty tools, **use Apple's API
directly** — the assembler has nothing to relieve and can only cost you.

That row survived a deliberate attempt to break it. The obvious objection is
that Apple's API cannot *rank*, so selection should pay off before the window
fills — and the first corpus padded with `calculator` and `base64_codec` was
too easy to test that. Re-run at twenty tools with confusable near-neighbours
instead (`start_fast`, `end_fast`, `get_fasting_stats` beside
`get_fasting_status`), both arms fit the window:

| 20 tools | bare provider | with the context layer |
|---|---|---|
| easy distractors | 83% | 83% |
| confusable distractors | 83% | 83% |

No separation. The on-device model picks correctly among near-neighbours on
its own, and ranking does not improve on it. Caveat worth stating: tool
accuracy sat at 83% in every arm, so this corpus is saturated and could not
have detected a small gain. The claim is "no effect large enough for six
cases to see", not "no effect".

The second row is the reason this package exists. Connect one MCP server and
fifty tools arrive at once; the request crosses 4,096 tokens and
FoundationModels throws `exceededContextWindowSize` rather than truncating.
Not a worse answer — no answer, on every single turn. That is the wall Aria
is built for, and the crossover is the whole story.

Run it yourself: `ARIA_RUN_EVALS=1 swift test --filter TaskEvalTests`.

## Why this exists

On-device models are small. The interesting problems are not "how do I call a
tool" — they are what happens on turn nine, with thirty tools registered, a
memory store, and a 4,096-token ceiling that **refuses** rather than truncates.
Every item below is a failure observed in a shipping app, and the fix is in the
box:

| What goes wrong | What Aria does |
|---|---|
| Request refused at 4,096 tokens, whole turn lost | `ContextAssembler` budgets prompt + tools + history together, and reports where every token went |
| 30 tools in the prompt; the model calls the wrong one | `ToolSelector` ranks per turn — lexical, embedding, or fused |
| A model invents a "fact" about the user; it is stored forever | `MemoryGate` provenance: a fact must trace back to what the user actually said |
| A tool fails and the model fabricates the answer instead | Failure guidance travels with the result |
| Swapping your embedding model silently empties memory | Vectors are keyed by embedder identity, with a re-embed migration |
| A thinking model's `<think>` blocks eat the history budget | Past-turn reasoning is not budgeted |

None of these are theoretical. [Release notes](https://github.com/prasadpamidi/aria/releases)
carry the traces.

## Measure it, don't trust it

Tool selection is the part most likely to be wrong for *your* tool surface, so
`AriaTesting` ships the harness rather than just the numbers:

```swift
let report = await ToolSelectionEval(corpus: myTools, cases: myQueries)
    .run(mySelector, label: "fused")
// fused: hit 100% · top-1 67% · MRR 0.79 · misled 0% · avg sent 7.5
```

Measured on one 12-query corpus, each fused with lexical matching:

| encoder | hit | MRR | avg tools sent |
|---|---|---|---|
| lexical only | 67% | 0.61 | — |
| + `NLEmbedding` | 58% | 0.39 | — |
| + Apple contextual | 92% | 0.72 | 10.0 |
| + MLX `bge-small` | **100%** | **0.79** | **7.5** |

Skills flood the same window, and get the same treatment. A catalogue is
pasted whole into every turn unless it is ranked — and each irrelevant skill
is not just its line in the prompt but a chance the model *loads* it, costing
a round-trip and a body-sized result. Ten skills, five queries:

| catalogue | recall | irrelevant skills offered / turn | block size |
|---|---|---|---|
| unranked | 100% | 9.4 | 350 tok |
| ranked, lexical | 100% | **0.2** | **60 tok** |

Recall is the constraint, not the headline: ranking that hides the skill a
turn needs is worse than no ranking at all.

Apple's `NLEmbedding` measures *worse than no encoder at all* — averaged static
word vectors put everything user-shaped near everything else. That is the kind of
thing you only learn by measuring, which is why the harness ships.

## What's in the box

- **Agent** — tool-calling loop, streaming events, middleware (history, windowing,
  summarization, RAG, fact extraction), provider-agnostic structured output.
- **Context** — `ContextAssembler`, `ContextBudget`, `TokenCounter`, `ToolSelector`.
- **Memory** — SQLite history + vector store, embedder abstraction, gated writes.
- **WorkflowKit** — Codable workflows, capability broker, JS plugin steps, MCP.
  [docs](docs/workflowkit.md)
- **AgentKit** — Codable agent definitions, human-in-the-loop approval, checkpoints.
  [docs](docs/agentkit.md)
- **Skills** — Anthropic-style `SKILL.md` bundles with on-demand loading.
  [docs](docs/skills.md)
- **Observability** — OpenTelemetry GenAI spans; session record + replay for
  regression tests.

Core is platform-agnostic and builds on Linux. Apple-specific implementations
live in `AriaApple`.

> **Status:** 0.x and moving. Used in production by two apps. Breaking changes
> land on minor versions and are listed in the release notes.

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

### Custom Apple language models (iOS 27+)

`AriaApple` accepts any Foundation Models `LanguageModel`, so an app can run a
Core AI model through the same `LLMProvider`, agent, tool, memory, and middleware
surfaces as Apple's system model:

```swift
import Aria
import AriaApple
import CoreAILanguageModels
import FoundationModels

let model = try await CoreAILanguageModel(resourcesAt: modelResourcesURL)
let provider = FoundationModelsProvider(
    model: model,
    capabilities: ProviderCapabilities(
        modelIdentifier: "coreai.qwen3-0.6b",
        supportsToolUse: model.capabilities.contains(.toolCalling),
        supportsStructuredOutput: model.capabilities.contains(.guidedGeneration)
    )
)
```

The app owns the Core AI package dependency, model resources, device-eligibility
checks, and fallback policy. Aria depends only on Foundation Models protocols and
does not silently replace an injected model when it cannot load or execute.

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
