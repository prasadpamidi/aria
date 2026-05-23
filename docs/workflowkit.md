# WorkflowKit

WorkflowKit is Aria's workflow runtime. It's the layer that turns a
user-editable, Codable `Workflow` value into something that streams
events out of a `StateGraph<WorkflowState>`. The runtime owns four
moving parts:

- A **Codable workflow model** (`Workflow`, `WorkflowNode`) the
  editor reads and writes.
- A **GRDB-backed persistence layer** (`WorkflowStore`,
  `WorkflowCatalog`) for user-authored and shipped workflows.
- A **compiler** (`WorkflowCompiler`) that lowers `Workflow` JSON
  into `Aria.CompiledStateGraph<WorkflowState>`, and a thin
  **runner** (`WorkflowRunner`) that drives it.
- A **capability broker** (`CapabilityBroker`) that mediates every
  side-effecting call (Calendar, Health, Files, Notifications…) and
  enforces per-caller scope grants.

Everything lives in `Sources/WorkflowKit/` under `Model/`, `Engine/`,
`Capabilities/`, `Storage/`, and `Seed/`. WorkflowKit sits one layer
above Aria's core (`Layers 1–6` — see [`architecture.md`](architecture.md))
and depends only on `Aria` plus `GRDB`.

## Workflow shape

A workflow is an ordered list of nodes plus optional layout edges:

```swift
public struct Workflow: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var nodes: [WorkflowNode]
    public var edges: [WorkflowEdge]
    public var triggers: Set<Trigger>           // .manual, .shortcuts, .urlScheme
    public var toolPolicy: ToolPolicy           // per-workflow capability allowlist
    public var memoryPolicy: MemoryPolicy       // .isolated | .shared thread
    public var enabledSkillIDs: Set<UUID>       // skills exposed to every LLM step
    // …timestamps, layout overrides, time-of-day tags
}
```

`WorkflowNode` is a discriminated union. Each variant carries only
the data its execution path needs:

| Variant | Step type | Purpose |
| --- | --- | --- |
| `.llm` | `LLMStep` | One agent turn. Prompt template + optional structured output. Carries `serverProviderID`, `mlxModelID`, `extraSkillIDs`, `disabledSkillIDs`. |
| `.capability` | `CapabilityStep` | Native capability call (`calendar.eventsToday`, `health.recentSteps`, …). |
| `.pluginTool` | `PluginToolStep` | Deterministic invocation of a JS plugin (`.aria-tool`) by `pluginID`. |
| `.mcpTool` | `MCPToolStep` | JSON-RPC call to an external MCP server. Auth via `credentialID`. |
| `.transform` | `TransformStep` | Small JS expression to reshape bindings. |
| `.branch` | `BranchStep` | Conditional fork with `trueBranch` / `falseBranch` / `joinNodeID`. |
| `.parallel` | `ParallelStep` | Fan-out → fan-in with last-write-wins merge. |
| `.loop` | `LoopStep` | While-loop with hard `maxIterations` cap. |
| `.output` | `OutputStep` | Terminal node. Maps declared outputs to templated strings. |

Every step writes one named slot in `WorkflowState.bindings`
(`outputBinding`) and reads upstream slots via `{{stepId.field}}`
interpolation (`TemplateInterpolator`). `input.*` is reserved for
the arguments the caller hands to `WorkflowRunner.run(_:input:)`.

Triggers, the input/output schemas, and `toolPolicy` are advisory
metadata the host app uses to decide which surfaces to register —
the runtime itself only acts on `nodes` + `edges`.

## Compile and run

`WorkflowCompiler` is a pure transform: `Workflow` →
`CompiledStateGraph<WorkflowState>`. It takes injection seams for
every runtime dependency:

```swift
public init(
    broker: CapabilityBroker,
    llmProvider: any WorkflowLLMProvider,
    jsEvaluator: any WorkflowJSEvaluator = ThrowingJSEvaluator(),
    pluginToolBroker: (any PluginToolBroker)? = nil,
    serverLLMResolver: ServerLLMProviderResolver? = nil,
    mlxLLMResolver: MLXLLMProviderResolver? = nil,
    mcpCredentialResolver: MCPCredentialResolver? = nil,
    skillResolver: WorkflowSkillResolver? = nil
)
```

`WorkflowRunner` wraps the compiler:

```swift
public func run(
    _ workflow: Workflow,
    input: [String: JSONValue] = [:],
    callerPluginID: String = "avyra.builtin.host",
    attended: Bool = true
) async throws -> [String: JSONValue]

public func runStreaming(
    _ workflow: Workflow,
    input: [String: JSONValue] = [:],
    callerPluginID: String = "...",
    attended: Bool = true
) -> AsyncThrowingStream<WorkflowRunEvent, any Error>
```

`WorkflowRunEvent` is the streaming surface a UI subscribes to:
`.stepStarted(nodeID:)` → `.stepCompleted(nodeID:outputBinding:value:)`
(or `.stepFailed`) → `.finished(result:)` (or `.failed`).

## Capability broker

`CapabilityBroker` is the chokepoint for every side-effecting call.
Two responsibilities: route a `(CapabilityID, method)` pair to the
registered impl, and check the caller's scope grants before
forwarding. Built-in capabilities:

| `CapabilityID` | Methods | Backed by |
| --- | --- | --- |
| `.secrets` | `read`, `write`, `list`, `delete` | `KeychainBackend` |
| `.calendar` | `eventsToday`, `eventsBetween`, `upcomingReminders`, `createEvent`, `createReminder` | `EventKitCalendarBackend` |
| `.health` | `recentSteps`, `lastSleep`, `lastWorkout`, `waterToday` | `HealthKitBackend` |
| `.location` | `currentLocation`, `geocode` | `CoreLocationBackend` |
| `.files` | `readText`, `readPDF` | Security-scoped URL reads |
| `.clipboard` | `read`, `write` | `UIKitClipboardBackend` |
| `.share` | `present` | `UIKitShareBackend` |
| `.notifications` | `schedule`, `cancel` | `UNNotificationsBackend` |
| `.http` | `request` | `HTTPTool` adapter |
| `.focus` | `current`, `suggest` | `INFocusBackend` |
| `.shortcuts` | `run` | `UIKitShortcutsBackend` |

Every capability conforms to `Capability` — declare your `id` and
`supportedMethods`, and implement one `call(method:arguments:context:)`
that returns a `JSONValue`. Tests inject `InMemoryCalendarBackend`,
`InMemoryHealthBackend`, etc. so the test runner never needs system
authorization.

Scope enforcement runs through `CapabilityScope` (`pluginID +
capability + optional method allowlist`). The broker's
`firstPartyCallerPrefix` (default `"sdk.builtin."`) short-circuits
the check for host-shipped workflows — pass your own prefix
(`"avyra.builtin."`, `"niora.builtin."`, …) to `init` so caller ids
don't collide across processes. User-installed plugins must have
been granted a scope explicitly; an ungranted call surfaces
`CapabilityError.notGranted(scope)` so the consent layer knows what
to ask for.

## Server-LLM routing

LLM steps can target an on-device provider, a cloud provider, or an
MLX-served local model. The choice is per-step:

```swift
LLMStep(
    promptTemplate: "...",
    outputBinding: "draft",
    serverProviderID: openAIProviderID  // resolved at compile time
)
```

`ServerLLMProviderResolver` is `@Sendable (UUID) async -> (any
WorkflowLLMProvider)?`. The app builds the closure with read access
to its credential store and provider registry — `WorkflowKit`
never sees raw API keys. Returning `nil` falls back to the
compiler's default `llmProvider`. Concrete adapters ship for OpenAI
(`OpenAIWorkflowLLMProvider`), Anthropic
(`AnthropicWorkflowLLMProvider`), and Gemini
(`GeminiWorkflowLLMProvider`); the OpenAI variant covers any
OpenAI-compatible endpoint.

A single workflow can mix on-device and cloud steps — the compiler
resolves each LLM step independently at graph-build time. See the
[Remote-LLM orchestration](../README.md#remote-llm-orchestration)
section in the README for current limitations around tool calling
and streaming-semantics edge cases.

## JS plugin steps

`PluginToolStep` invokes a JS plugin without going through the LLM.
`PluginToolBroker` (typically `JSPluginToolBroker` backed by an
`AriaToolsJS.JSToolProvider`) looks up the loaded plugin by id and
forwards the JSON input to its `call(input)` function. The same
`.aria-tool` bundle a chat agent calls is callable as a workflow
step — see [`docs/plugins.md`](plugins.md) for the bundle format
and runtime details.

## Skills resolution

`LLMStep.extraSkillIDs` and `Workflow.enabledSkillIDs` declare
which skills a step should see. The compiler unions them, subtracts
the step's `disabledSkillIDs`, and asks the `WorkflowSkillResolver`
closure to expand the resulting `Set<UUID>` into a markdown block.
Workflow LLM steps are single-shot — they don't run an agent loop,
so the `load_skill` tool the chat path uses can't fire inside them.
Every requested skill's description + body inlines into the step's
system prompt at compile time. See [`docs/skills.md`](skills.md)
for the broader skill model.

## MCP integration

`MCPToolStep` calls a tool on an external MCP (Model Context
Protocol) server over the Streamable HTTP transport. Each step
names a `serverURL`, an optional `credentialID`, the `toolName`,
and an `argsTemplate` map. At run time, `MCPClient` does the
JSON-RPC handshake (`initialize` → `notifications/initialized` →
`tools/call`) and returns the concatenated `text` content blocks
the server emitted.

`MCPCredentialResolver` is the bridge to the host's credential
vault: `@Sendable (UUID) async -> MCPCredential?` where
`MCPCredential` is either `.bearer(token)` or `.basic(username:
password:)`. A step that names a credential but resolves to `nil`
fails closed with `MCPError.missingCredential` rather than sending
an unauthenticated request.

## Storage

`WorkflowStore` is GRDB-backed. CRUD operations (`save`, `load`,
`list`, `delete`) are `Sendable`; the underlying
`DatabaseQueue` serialises writes. `list()` returns lightweight
`Summary` rows (id, name, updatedAt) so a library list view
doesn't decode every blob.

`WorkflowCatalog` is a `@MainActor @Observable` in-memory registry
for shipped (first-party) workflows the user can browse and Remix.
It's distinct from `WorkflowStore` — store holds user-authored
content, catalog holds host-shipped content that the user can
clone into the store but not edit in place. `SeedInstaller` is the
canonical path for populating the catalogue on first launch.

## Example: calendar → LLM summary → reminder

A workflow that reads today's events, summarises them on-device,
and writes tomorrow's prep reminder.

```swift
import Aria
import AriaApple
import WorkflowKit

let events = CapabilityStep(
    capability: .calendar,
    method: "eventsToday",
    outputBinding: "events"
)

let summary = LLMStep(
    promptTemplate: """
    Summarise today's meetings in three bullet points.

    Events: {{events}}
    """,
    outputBinding: "summary"
)

let reminder = CapabilityStep(
    capability: .calendar,
    method: "createReminder",
    argsTemplate: [
        "title": "Prep for tomorrow",
        "notes": "{{summary}}"
    ],
    outputBinding: "reminderID"
)

let output = OutputStep(fields: ["digest": "{{summary}}"])

let workflow = Workflow(
    name: "Evening Brief",
    nodes: [
        .capability(events),
        .llm(summary),
        .capability(reminder),
        .output(output)
    ]
)
```

Compile and run:

```swift
let broker = CapabilityBroker(firstPartyCallerPrefix: "myapp.builtin.")
await broker.register(CalendarRemindersCapability(backend: EventKitCalendarBackend()))

let compiler = WorkflowCompiler(
    broker: broker,
    llmProvider: FoundationModelsWorkflowLLMProvider()
)
let runner = WorkflowRunner(compiler: compiler)

for try await event in runner.runStreaming(workflow) {
    switch event {
    case let .stepStarted(nodeID):
        print("→ \(nodeID)")
    case let .stepCompleted(_, binding, value):
        print("  \(binding ?? "-") = \(value ?? .null)")
    case let .finished(result):
        print("done: \(result)")
    case let .failed(message):
        print("failed: \(message)")
    case .stepFailed:
        break
    }
}
```

### Cloud variant

Swap the summary step to OpenAI by setting `serverProviderID` and
wiring a resolver:

```swift
let openAIProviderID = UUID(uuidString: "…")!

let summary = LLMStep(
    promptTemplate: "Summarise today's meetings…",
    outputBinding: "summary",
    serverProviderID: openAIProviderID
)

let compiler = WorkflowCompiler(
    broker: broker,
    llmProvider: FoundationModelsWorkflowLLMProvider(),
    serverLLMResolver: { providerID in
        guard providerID == openAIProviderID else { return nil }
        return await myProviderStore.makeOpenAIProvider()
    }
)
```

The capability steps still run on-device; only the LLM turn round-
trips to OpenAI. Tool-calling against cloud providers, streaming
semantics, and provider error normalisation each have limitations
worth reading before depending on cloud routing in production —
see the README's [Remote-LLM orchestration](../README.md#remote-llm-orchestration)
section for the current state.
