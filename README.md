# Aria

**Composable on-device agent runtime for Apple platforms.**

Aria is a Swift library for building agent-driven applications that run on-device using Apple's FoundationModels, MLX, or Core ML. It provides a tool-calling agent runtime, type-safe abstractions over local LLMs, memory primitives, and an optional graph orchestration layer.

The core is platform-agnostic and builds on Linux. Apple-specific implementations live in `AriaApple`.

> **Status:** Layers 1–6 are implemented and tested on iOS 26 / macOS 26 / Linux. Headline features:
>
> - Tool-calling **Agent** with streaming events, the full middleware stack (history persistence, windowing, summarization, RAG retrieval, automatic fact extraction), and **provider-agnostic** structured-output `respond(_:as:)` that works against FoundationModels and any cloud `LLMProvider`.
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
┌─────────────────────────────────────────────────┐
│  Layer 6:  StateGraph     (optional graphs)     │
├─────────────────────────────────────────────────┤
│  Layer 5:  Agent          (tool-calling loop)   │
├─────────────────────────────────────────────────┤
│  Layer 4:  Memory         (history, vectors)    │
├─────────────────────────────────────────────────┤
│  Layer 3:  Providers      (LLM, Tool, Embedder) │
├─────────────────────────────────────────────────┤
│  Layer 2:  Runnable       (composability)       │
├─────────────────────────────────────────────────┤
│  Layer 1:  Foundation     (data model)          │
└─────────────────────────────────────────────────┘
```

A layer depends only on layers below. See [`docs/architecture.md`](docs/architecture.md).

## Package layout

```
Sources/
├── Aria/                Layers 1–6, platform-agnostic (Linux-buildable)
├── AriaTesting/         Mocks and fixtures
├── AriaApple/           FoundationModels, MLX, SwiftData, sqlite-vec
└── AriaTools/           Cross-platform tool implementations
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

## Build and test

```bash
swift build                                # build the package
swift test                                 # run all tests
swift test --filter AriaTests              # core tests (Linux-safe)
swift run AriaCLI                          # run the CLI demo

# iOS sample app
open Examples/SampleApp/AriaSample.xcodeproj
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
bundle exec fastlane package_tests       # swift test
bundle exec fastlane sample_build        # build AriaSample on iOS Simulator
bundle exec fastlane lint                # SwiftLint
bundle exec fastlane format              # SwiftFormat (in place)
bundle exec fastlane quality             # format --lint + lint
bundle exec fastlane quality fix:true    # auto-fix both
```

See [`AGENTS.md`](AGENTS.md) for the full lane reference.

## Documentation

- [`docs/overview.md`](docs/overview.md) — what Aria is, who it's for
- [`docs/principles.md`](docs/principles.md) — architectural principles
- [`docs/architecture.md`](docs/architecture.md) — layered design and module layout
- [`docs/platform-boundary.md`](docs/platform-boundary.md) — cross-platform discipline
- [`docs/observability.md`](docs/observability.md) — OTel tracing/metrics + session recording / replay
- [`docs/layers/`](docs/layers/) — per-layer specs
- [`docs/decisions/`](docs/decisions/) — architecture decision records
- [`docs/glossary.md`](docs/glossary.md) — terminology

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) and [`AGENTS.md`](AGENTS.md). Aria is a clean-room implementation; please read [`NOTICE.md`](NOTICE.md) before contributing.

## License

[MIT](LICENSE)
