# Aria

**Composable on-device agent runtime for Apple platforms.**

Aria is a Swift library for building agent-driven applications that run on-device using Apple's FoundationModels, MLX, or Core ML. It provides a tool-calling agent runtime, type-safe abstractions over local LLMs, memory primitives, and an optional graph orchestration layer.

The core is platform-agnostic and builds on Linux. Apple-specific implementations live in `AriaApple`.

> **Status:** Architecture and design phase. Protocols and types described in [`docs/`](docs/) are the target design; implementation is pending.

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

> Implementation pending. The snippets below describe the *target* API.

```swift
import Aria
import AriaApple

let agent = Agent(config: AgentConfig(
    provider: FoundationModelsProvider(model: .systemDefault),
    tools: [AnyTool(WeatherTool(httpClient: client))],
    systemPrompt: "You are a helpful assistant.",
    history: SwiftDataChatHistory(),
    checkpointer: SwiftDataCheckpointer()
))

for try await event in agent.stream(.message(.user("What's the weather in Tokyo?")), options: .init()) {
    switch event {
    case .textDelta(let chunk): print(chunk, terminator: "")
    case .toolCallRequested(let call): print("[calling \(call.name)]")
    case .finish: print("\n[done]")
    default: break
    }
}
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

### Fastlane

Routine work goes through Fastlane lanes. Set up with `brew bundle && bundle install`, then:

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
- [`docs/layers/`](docs/layers/) — per-layer specs
- [`docs/decisions/`](docs/decisions/) — architecture decision records
- [`docs/glossary.md`](docs/glossary.md) — terminology

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) and [`AGENTS.md`](AGENTS.md). Aria is a clean-room implementation; please read [`NOTICE.md`](NOTICE.md) before contributing.

## License

[MIT](LICENSE)
