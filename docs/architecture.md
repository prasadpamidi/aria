# Architecture

Aria is organized as six strictly-layered components plus a platform-specific implementation module. This document describes the layers, the dependency graph, and the Swift Package layout.

## The six layers

```
┌─────────────────────────────────────────────────────────────┐
│  Layer 6:  StateGraph     (optional, for branching agents)  │
├─────────────────────────────────────────────────────────────┤
│  Layer 5:  Agent          (the tool-calling loop)           │
├─────────────────────────────────────────────────────────────┤
│  Layer 4:  Memory         (History, Checkpointer, Vector)   │
├─────────────────────────────────────────────────────────────┤
│  Layer 3:  Providers      (LLMProvider, Tool, Embedder)     │
├─────────────────────────────────────────────────────────────┤
│  Layer 2:  Runnable       (composable Input → Output)       │
├─────────────────────────────────────────────────────────────┤
│  Layer 1:  Foundation     (Message, JSONSchema, Events)     │
└─────────────────────────────────────────────────────────────┘
```

A layer may depend only on layers below it. Layer 6 depends on 1–5; layer 1 depends on nothing but the Swift Standard Library and a small subset of Foundation.

## What lives where

### Layer 1 — Foundation
Pure data. Value types and enums with no behavior beyond `Codable`/`Sendable`.

- `Message`, `ContentPart`, `ToolCall`, `ToolDefinition`
- `ProviderEvent`, `AgentEvent`, `FinishReason`
- `JSONSchema`, `JSONValue`
- `AgentError`, `RunOptions`, `CancellationToken`

See [layers/01-foundation.md](layers/01-foundation.md).

### Layer 2 — Runnable
The composability primitive.

- `Runnable<Input, Output>` protocol
- Combinators: `pipe`, `map`, `parallel`, `withRetry`, `withTimeout`, `withObserver`
- `Observer` protocol (no-op default)

See [layers/02-runnable.md](layers/02-runnable.md).

### Layer 3 — Providers
The model and tool boundary.

- `LLMProvider` protocol, `ProviderCapabilities`, `GenerationOptions`
- `Tool` protocol, `AnyTool` (type-erased), `ToolContext`
- `Embedder` protocol
- `Tokenizer` protocol

See [layers/03-providers.md](layers/03-providers.md).

### Layer 4 — Memory
Storage and recall protocols.

- `ChatHistory` protocol
- `Checkpointer` protocol
- `VectorStore` protocol
- `MemoryStore` protocol (composes Embedder + VectorStore)
- `HistoryPolicy` (how messages are selected for the model context)
- In-memory default implementations

See [layers/04-memory.md](layers/04-memory.md).

### Layer 5 — Agent
The orchestrator.

- `AgentConfig`, `AgentState`, `AgentInput`
- `AgentMiddleware` protocol
- `Agent` actor (conforms to `Runnable<AgentInput, AgentEvent>`)
- The tool-calling control loop

See [layers/05-agent.md](layers/05-agent.md).

### Layer 6 — StateGraph
Optional graph orchestration for branching, multi-node workflows.

- `StateGraph<State>` (conforms to `Runnable<State, State>`)
- `Node`, `Edge`, `Channel` for state merging
- Conditional edges and reducers

See [layers/06-stategraph.md](layers/06-stategraph.md).

## Dependency graph

```
                 ┌──────────────┐
                 │  StateGraph  │  Layer 6
                 └──────┬───────┘
                        │
                 ┌──────▼───────┐
                 │    Agent     │  Layer 5
                 └──────┬───────┘
                        │
              ┌─────────┼─────────┐
              │         │         │
        ┌─────▼───┐ ┌───▼────┐ ┌──▼──────────┐
        │ Memory  │ │Providers│ │ Middleware  │  Layer 4 / 3
        └────┬────┘ └────┬───┘ └──────┬──────┘
             │           │            │
             └────┬──────┴────────────┘
                  │
            ┌─────▼─────┐
            │  Runnable │  Layer 2
            └─────┬─────┘
                  │
            ┌─────▼─────┐
            │Foundation │  Layer 1
            └───────────┘
```

`AgentMiddleware` lives at Layer 5 conceptually but its protocol surface is reachable from any layer that needs to expose hooks.

## Swift Package layout

The repository is a single Swift Package with multiple targets. Targets map to library products that consumers can depend on à la carte.

```
aria/
├── Package.swift
├── Sources/
│   ├── Aria/                    ← Layers 1–6, platform-agnostic (Linux-buildable)
│   │   ├── Foundation/
│   │   ├── Runnable/
│   │   ├── Providers/           (protocols only)
│   │   ├── Memory/              (protocols + in-memory defaults)
│   │   ├── Agent/               (Aria.Agent loop + middleware protocol)
│   │   └── StateGraph/
│   │
│   ├── AriaTesting/             ← Mocks, fixtures, SessionReplayer
│   │   ├── MockLLMProvider.swift
│   │   ├── RecordingObserver.swift
│   │   └── TestTools.swift
│   │
│   ├── AriaApple/               ← Apple-platform implementations (Apple-only)
│   │   ├── Providers/
│   │   │   └── FoundationModelsProvider.swift
│   │   ├── Memory/
│   │   │   ├── GRDBChatHistory.swift
│   │   │   ├── GRDBCheckpointer.swift
│   │   │   └── GRDBVectorStore.swift
│   │   ├── Embedders/
│   │   │   └── NLEmbeddingEmbedder.swift
│   │   └── Observability/
│   │       └── OSLogObserver.swift
│   │
│   ├── AriaTools/               ← Cross-platform tool implementations
│   │   ├── HTTPTool.swift       (uses injected HTTPClient)
│   │   ├── CalculatorTool.swift
│   │   ├── JSONPathTool.swift
│   │   └── RegexTool.swift
│   │
│   ├── AriaToolsJS/             ← JS plugin tools (`.aria-tool` sandbox)
│   │   ├── JSToolProvider.swift
│   │   ├── JSContextHost.swift
│   │   └── PluginManifest.swift
│   │
│   ├── AriaVoice/               ← Speech.framework STT + AVSpeech TTS
│   ├── AriaMLX/                 ← MLX-backed LLMProvider (trait: `MLX`)
│   ├── AriaVoiceKokoro/         ← Kokoro 82M TTS (trait: `VoiceKokoro`)
│   │
│   ├── WorkflowKit/             ← Recipes-you-write runtime
│   │   ├── Model/               (Codable Workflow + step kinds)
│   │   ├── Storage/             (GRDB store + migrator)
│   │   ├── Engine/              (compile → StateGraph; capability broker)
│   │   ├── Capabilities/        (Calendar, Reminders, Files, …)
│   │   └── Plugins/             (plugin step + manifest)
│   │
│   ├── AgentKit/                ← Goals-you-delegate runtime (Apple-only)
│   │   ├── Model/               (AgentDefinition, AgentRunRecord, AgentProposal)
│   │   ├── Storage/             (file-JSON AgentStore + AgentRunStore)
│   │   ├── Engine/              (AgentCompiler, ProposeTool, ApprovalSink, CapabilityCatalog)
│   │   ├── Runtime/             (AgentRuntime, AgentRunEvent, CheckpointMiddleware)
│   │   └── Catalog/             (AgentCatalog, AgentPersona)
│   │
│   └── AriaCLI/                 ← Demo CLI: record + replay a run
│
└── Tests/
    ├── AriaTests/               ← Run on Linux + Apple
    ├── AriaAppleTests/          ← macOS only
    └── WorkflowKitTests/        ← Includes NotificationsCapabilityTests etc.
```

### Target dependencies

| Target | Depends on | Builds on |
|---|---|---|
| `Aria` | (only stdlib + Foundation subset + swift-log) | Linux, macOS, iOS |
| `AriaTesting` | `Aria` | Linux, macOS, iOS |
| `AriaApple` | `Aria`, FoundationModels, GRDB | macOS 15+, iOS 18+, watchOS, tvOS, visionOS |
| `AriaTools` | `Aria` | Linux, macOS, iOS |
| `AriaToolsJS` | `Aria`, JavaScriptCore | Apple-only |
| `AriaVoice` | `Aria`, Speech, AVFoundation | Apple-only |
| `AriaMLX` (trait) | `Aria`, `AriaApple`, mlx-swift-lm | Apple Silicon |
| `AriaVoiceKokoro` (trait) | `Aria`, kokoro-ios | Apple Silicon |
| `WorkflowKit` | `Aria`, `AriaApple` (GRDB), `AriaTools` | Apple-only |
| `AgentKit` | `Aria`, `AriaApple`, `WorkflowKit` | Apple-only (iOS 26+) |
| `AriaCLI` | `Aria`, `AriaTesting` | macOS, Linux |

**Typical iOS app**: depends on `Aria` + `AriaApple` + `AriaTools`
+ `AriaToolsJS` + `WorkflowKit`. Add `AgentKit` if shipping
agent-style features. Flip the `MLX` / `VoiceKokoro` traits on
for on-device 8B+ LLMs or Kokoro TTS.

**Portable / Linux**: depends on `Aria` only. Provides own
platform implementations of `LLMProvider`, `ChatHistory`,
`VectorStore`, etc.

## Testing strategy

| Test target | Runs on | Tests what |
|---|---|---|
| `AriaTests` | Linux CI + Apple CI | Layers 1–6 using `MockLLMProvider`, in-memory memory, fixture tools |
| `AriaAppleTests` | Apple CI only | FoundationModels, MLX, SwiftData, sqlite-vec, Core ML |

The Linux build of `AriaTests` is the **mechanical enforcement** of the platform boundary. If anyone introduces an Apple-only import into `Aria`, the Linux CI breaks.

## Why this layout

- **One package, multiple modules.** Easier to version, easier for consumers to pin a single version. Modular consumption stays clean via library products.
- **`AriaApple` is a single module, not multiple.** Splitting `AriaAppleProviders`, `AriaAppleMemory`, etc. is premature. If the module grows past ~50 files, revisit.
- **`AriaTools` is cross-platform.** Tools that need Apple frameworks (Calendar, HealthKit) will live in `AriaApple` under a `Tools/` subfolder. The split is platform, not feature.
- **`AriaTesting` is a public target.** Consumers writing their own provider implementations should be able to test against Aria's mocks. This is a first-class use case.

## What's not in this picture (yet)

- **`AriaAndroid`**: when (if) Android support comes via Skip, KMP, or the Swift Android toolchain, it gets its own module. The protocol contracts in `Aria` already accommodate this.
- **`AriaServer`**: not planned. If a server use case emerges, a thin module could provide HTTP-based provider and tool implementations.
- **`AriaUI`**: not planned. UI is the application's job. Aria emits events; SwiftUI views render them.
