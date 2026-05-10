# Observability

Aria ships an OpenTelemetry-compatible observability layer plus a self-contained session-recording format. The two compose: one is for live monitoring, the other for offline replay.

```
┌────────────────────────┐    ┌─────────────────────────┐
│  Live (OpenTelemetry)  │    │   Offline (Aria)        │
│  swift-distributed-    │    │   SessionBundle JSON    │
│  tracing + swift-      │    │   ship anywhere,        │
│  metrics → swift-otel  │    │   replay anywhere       │
│  → Phoenix, Honeycomb  │    │                         │
│  Datadog, Tempo, etc.  │    │                         │
└────────────────────────┘    └─────────────────────────┘
```

---

## Live tracing + metrics

Aria emits spans and metrics through the standard Swift Server packages. Defaults are no-op; consumers wire up a backend at process start.

### Wiring up swift-otel

```swift
import OTel
import OTLPGRPC
import Metrics
import ServiceLifecycle
import Tracing

let resource = OTelResource(attributes: [
    "service.name": "my-aria-app",
    "service.version": "1.0",
])

let tracer = try OTelTracer(
    resourceDetector: .manual(resource),
    exporter: try OTLPGRPCSpanExporter(),
    propagator: OTelMultiplexPropagator([
        OTelW3CPropagator(),
    ])
)
InstrumentationSystem.bootstrap(tracer)

let metrics = try OTelMetrics(
    resourceDetector: .manual(resource),
    exporter: try OTLPGRPCMetricExporter()
)
MetricsSystem.bootstrap(metrics)

// Aria emits everything below automatically once bootstrapped.
```

### Span tree

```
agent.run                          gen_ai.system, gen_ai.request.model,
                                   gen_ai.operation.name = "chat",
                                   aria.thread_id
├── agent.step                     aria.agent.step_index
│   ├── provider.stream            gen_ai.usage.input_tokens / output_tokens,
│   │                              gen_ai.response.finish_reasons
│   └── tool.execute               gen_ai.tool.name, gen_ai.tool.call.id
│
agent.respond                      gen_ai.operation.name = "structured_output"
│
state_graph.run                    aria.state_graph.reducer_count
├── state_graph.node               aria.state_graph.node
└── state_graph.parallel           aria.state_graph.parallel.branches
state_graph.resume                 aria.thread_id
│
memory.recall                      aria.memory.namespace,
                                   aria.memory.top_k,
                                   aria.memory.matches.count
memory.remember                    aria.memory.namespace,
                                   aria.memory.item.id
```

All span names + attribute keys live in `Aria.AriaSemConv` so dashboards, alerts, and instrumentation tests reference the same identifiers.

### Metrics

| Metric | Type | Dimensions |
|---|---|---|
| `gen_ai.client.token.usage` | Recorder | `gen_ai.system`, `gen_ai.token.type` |
| `gen_ai.client.operation.duration` | Recorder | `gen_ai.system`, `gen_ai.operation.name` |
| `aria.agent.steps_total` | Counter | — |
| `aria.tool.executions_total` | Counter | `tool.name`, `tool.is_error` |
| `aria.tool.duration_seconds` | Recorder | `tool.name` |
| `aria.state_graph.node_executions_total` | Counter | `node.name` |
| `aria.memory.recalls_total` | Counter | — |
| `aria.memory.remembers_total` | Counter | — |

### GenAI semantic conventions

Aria emits OpenTelemetry's [GenAI semantic conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/) where they apply (`gen_ai.system`, `gen_ai.request.model`, `gen_ai.usage.*`, `gen_ai.tool.*`). LLM-aware backends (Phoenix, Arize, Helicone) recognize these and auto-render runs as conversation traces — no custom dashboards required.

---

## Session recording + replay

When a backend isn't an option (offline, regression tests, sharing a repro), Aria can record a run into a self-contained `SessionBundle: Codable` and replay it elsewhere.

### Recording

```swift
let recorder = SessionRecorder()

// Agent capture (via middleware)
let recording = RecordingMiddleware(recorder: recorder)
recording.bind(
    providerSystem: "anthropic",
    providerModel: "claude-opus-4-7",
    systemPrompt: "…"
)
let agent = Agent(config: AgentConfig(
    provider: …,
    tools: …,
    middleware: [..., recording]
))

// State graph capture (via RunOptions)
_ = try await graph.build().run(
    initial: state,
    options: .init(recorder: recorder)
)

// Export
let bundle = await recorder.bundle()
let data = try JSONEncoder().encode(bundle)
```

`SessionBundle` covers:

- `AgentRecord` — provider identity, thread, system prompt, input messages, per-step `messagesBefore` / `messagesAfter`, final messages, finish reason.
- `StateGraphRecord` — every node visit with JSON-encoded input + output state and per-node duration.

Bundle is versioned (`version: "1"`) so the format is stable across Aria upgrades.

### Replay

`AriaTesting.SessionReplayer` consumes a bundle and produces:

- `mockProvider(from: AgentRecord)` — a `MockLLMProvider` whose stream events reproduce the recorded trajectory step-by-step. Tool calls go through `.toolCallStart` / `.toolCallEnd` so the replay agent's own tool registry handles dispatch.
- `tools(from: AgentRecord)` — an `[AnyTool]` registry that returns the recorded outputs for each call instead of dispatching live tools. Use this in place of the production tool list when re-running against I/O-heavy tools.
- `states(from: StateGraphRecord, as: State.self)` — decodes every node visit's input + output state back to typed `StateTransition<State>` values.

```swift
let bundle = try JSONDecoder().decode(SessionBundle.self, from: data)
let provider = SessionReplayer.mockProvider(from: bundle.agent!)
let tools    = SessionReplayer.tools(from: bundle.agent!)

let replayed = Agent(config: AgentConfig(
    provider: provider, tools: tools, threadId: "replay-1"
))
for try await event in replayed.stream(.message(.user("…"))) { … }
```

### CLI demo

`Examples/AriaCLI` runs the full record → bundle → replay loop against `MockLLMProvider`, prints the bundle JSON, and replays it. No Apple dependencies — runs on Linux too.

```bash
swift run AriaCLI
```
