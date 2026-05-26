# AgentKit

The reusable agent runtime that sits alongside `WorkflowKit` in
the Aria SDK. Where `WorkflowKit` runs **recipes you wrote**
(deterministic, author-defined step sequences), `AgentKit` runs
**goals you delegated** (open-ended, model-driven loops that
pick their own steps toward an outcome). Both compose the core
`Agent` loop from `Aria`; both call into the same
`CapabilityBroker`; either can be used standalone or together.

This doc covers the public surface, the runtime model, the
human-in-the-loop story, and the host-injection points
downstream consumers (avyra, niora, your app) wire up.

> **Platform:** Apple-only. The runtime is `@available(iOS 26,
> macOS 26)` because it depends on `FoundationModels`, `AriaApple`,
> and Apple-specific host integrations through `WorkflowKit`'s
> `CapabilityBroker`. The Codable model types (`AgentDefinition`,
> `AgentRunRecord`) work on Linux too, but you can't actually
> compile or run agents off-platform.

---

## Mental model: recipes vs. goals

Aria's two runtimes solve different problems:

```
┌─────────────────────────────┬─────────────────────────────────┐
│         WorkflowKit         │            AgentKit             │
├─────────────────────────────┼─────────────────────────────────┤
│  Recipe you wrote           │  Goal you delegated             │
│                             │                                 │
│  • Deterministic step order │  • Model picks its own steps    │
│  • Authored in a builder    │  • Authored as a system prompt  │
│  • Same steps every run     │  • Different path every run     │
│  • LLM steps + branches +   │  • One LLM call, many tool      │
│    loops + capability calls │    iterations, ends when done   │
│  • Compiled to StateGraph   │  • Composes Aria's Agent loop   │
│  • Best when the procedure  │  • Best when the procedure is   │
│    is known up front        │    open-ended or judgment-driven│
└─────────────────────────────┴─────────────────────────────────┘
```

**A workflow** is the right answer when you can write down the
steps: "summarize this PDF → extract action items → draft an
email." A user taps a tile, the runtime walks the graph, you get
the same result shape every time.

**An agent** is the right answer for "research X and write a
brief," "triage my inbox," "be my morning companion." The model
decides — at runtime — what to check, what tools to call, what
to propose, when to stop.

**Bridge:** agents can call workflows as tools (deterministic
subroutines). A stabilized agent can later be "graduated" into
a workflow.

---

## The runtime in one diagram

```
┌──────────────────────────────────────────────────────────────┐
│  Host app — wires the runtime, owns content + UI             │
│  ──────────────────────────────────────────────────────────  │
│                                                              │
│  AgentRuntime.boot(                                          │
│      store:           AgentStore,         ← Codable defs    │
│      runStore:        AgentRunStore,      ← per-run records  │
│      chatHistory:     ChatHistory,        ← message store    │
│      checkpointer:    Checkpointer,       ← run state        │
│      broker:          CapabilityBroker,   ← native side-effects│
│      providerFactory: AgentProviderFactory,                  │
│      extraTools:      AgentExtraToolsProvider                │
│  )                                                           │
│                                                              │
│  ┌──── two closures the host injects ─────────────────────┐  │
│  │  AgentProviderFactory                                  │  │
│  │   → Given an AgentDefinition, return an LLMProvider.   │  │
│  │     Host picks FoundationModels / MLX / server LLM.    │  │
│  │                                                        │  │
│  │  AgentExtraToolsProvider                               │  │
│  │   → Given an AgentDefinition + threadId, return        │  │
│  │     additional FoundationModelsToolKits — host's MCP   │  │
│  │     servers, workflow-as-tool wrappers, plugin tools,  │  │
│  │     load_skill, whatever else the host supports.       │  │
│  └────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────┐
│  AgentRuntime  (@MainActor actor, singleton-ish)             │
│  ──────────────────────────────────────────────────────────  │
│                                                              │
│  runStreaming(agentID:input:threadId:)                       │
│      → AsyncThrowingStream<AgentRunEvent, Error>             │
│        1. Load AgentDefinition from store                    │
│        2. Compile via AgentCompiler → Aria.Agent             │
│        3. Drive the stream, persist run record               │
│        4. Yield events (runStarted, stepStart, toolCall,     │
│           awaitingApproval, checkpointSaved, finished, …)    │
│                                                              │
│  resumeStreaming(runID:approval:)                            │
│      → Same stream shape; rehydrates from chatHistory by     │
│        threadId, feeds a continuation nudge, drives forward  │
└──────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────┐
│  Aria.Agent  +  middleware chain                             │
│  ──────────────────────────────────────────────────────────  │
│  [ HistoryMiddleware,                                        │
│    HistoryWindowMiddleware,                                  │
│    CheckpointMiddleware,                                     │
│    ApprovalMiddleware (when ProposeTool fires),              │
│    RecordingMiddleware ]                                     │
└──────────────────────────────────────────────────────────────┘
```

The host owns the four storage interfaces (it picks where
they live — file, GRDB, Keychain, whatever) and the two
closures. Everything else is in AgentKit.

---

## Public types

### `AgentDefinition` — Codable, the "what"

A single Swift value type that fully describes an agent.
Round-trips through JSON, persists in `AgentStore`, ships in
seed content, can be cloned and edited. The host doesn't store
behaviour as code — it stores `AgentDefinition`s as data and
recompiles to a fresh `Aria.Agent` every run.

```swift
public struct AgentDefinition: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var summary: String
    public var systemPrompt: String
    public var maxSteps: Int

    // Model routing — same shape as LLMStep.
    public var modelHint: ModelFamilyHint           // .foundationModels | .mlx | .server | .any
    public var serverProviderID: String?
    public var mlxModelID: String?

    // Tool allowlists — ids the runtime resolves to typed tools
    // via the host's extraTools closure + WorkflowKit's broker.
    public var enabledCapabilities: Set<CapabilityID>
    public var enabledCapabilityMethods: [CapabilityID: Set<String>]
    public var enabledPluginIDs: Set<String>
    public var enabledMCPToolRefs: Set<MCPToolRef>
    public var enabledWorkflowIDs: Set<UUID>
    public var enabledSkillIDs: Set<String>

    // Human-in-the-loop policy. `.autonomous` = no approval gates;
    // `.proposeThenConfirm(actions:)` = side-effecting tools listed
    // here must be proposed and host-executed on approval.
    public var approvalPolicy: ApprovalPolicy

    // Discovery + UI hints.
    public var triggers: [AgentTrigger]
    public var timeOfDayTags: [TimeOfDayTag]
    public var suggestedActions: [String]
    public var recommendsStrongerModel: Bool

    // Provenance — set when an agent was Remixed from a catalogue entry.
    public var parentAgentID: UUID?
    public var createdAt: Date
    public var updatedAt: Date
}
```

Mirrors `WorkflowKit.Workflow` in spirit — the persistent
authoring artifact. The runtime never mutates an
`AgentDefinition`; edits go through the host's `AgentStore`.

### `AgentStore` / `AgentRunStore` — JSON-file persistence

File-per-row JSON stores. One file per `AgentDefinition`, one
file per `AgentRunRecord`. The default directory layout lives
under `Application Support` (host-controlled). Designed for
low volume (tens of agents, hundreds of runs per user) — not a
write-heavy stream sink. Use `Checkpointer` for that.

```swift
public final class AgentStore {
    public func save(_ definition: AgentDefinition) throws
    public func load(id: UUID) throws -> AgentDefinition?
    public func list() throws -> [Summary]              // lightweight (no full body)
    public func delete(id: UUID) throws
    public func clone(from sourceID: UUID) throws -> UUID
}

public final class AgentRunStore {
    public func start(agentID: UUID, inputSummary: String, threadId: String?) throws -> AgentRunRecord
    public func update(id: UUID, mutating: (inout AgentRunRecord) -> Void) throws
    public func setProposal(id: UUID, _ proposal: AgentProposal?) throws
    public func listActive() throws -> [AgentRunRecord]   // running | awaitingApproval | paused
    public func load(id: UUID) throws -> AgentRunRecord?
}
```

### `AgentCompiler` — definition → `Aria.Agent`

Lowering. Resolves capabilities → tools (via
`CapabilityToolKitBuilder`), pulls extra tools from the host's
closure, builds the middleware chain, picks an `LLMProvider`,
and assembles an `AgentConfig`. Returns a fresh `Aria.Agent`
ready to stream.

The compiler stamps a **date anchor** at the top of every
system prompt:

```
Current date: 2026-05-26 (14:30 America/Los_Angeles)
Current local datetime: 2026-05-26T14:30:00
Current ISO-8601 instant (with offset): 2026-05-26T14:30:00-07:00

When you emit a datetime (e.g. `fireAt` for a reminder/notification), use ONE of these shapes:
  1. Local naïve datetime, no timezone suffix — the host interprets it in America/Los_Angeles.
     Example: one hour from now is exactly `2026-05-26T15:30:00`.
  2. ISO-8601 with the EXACT offset shown above — copy the suffix verbatim.

DO NOT append `Z`. DO NOT invent a different offset.
```

Small on-device LLMs hallucinate timezones without this; the
anchor lets them ground every "schedule for tomorrow at 6pm"
intent in real local-clock arithmetic.

### `AgentRuntime` — boot + stream

`@MainActor actor` with a static `shared` holder. The host
boots it once at app launch (after `WorkflowRuntime.boot`),
passing in the four storage interfaces, the broker, and the
two closures.

```swift
public actor AgentRuntime {
    public static var shared: AgentRuntime?

    public static func boot(
        store: AgentStore,
        runStore: AgentRunStore,
        chatHistory: any ChatHistory,
        checkpointer: any Checkpointer,
        broker: CapabilityBroker,
        providerFactory: @escaping AgentProviderFactory,
        extraTools: @escaping AgentExtraToolsProvider
    ) async

    public func runStreaming(
        agentID: UUID,
        input: AgentInput,
        threadId: String? = nil
    ) -> AsyncThrowingStream<AgentRunEvent, any Error>

    public func resumeStreaming(
        runID: UUID,
        approval: ApprovalResolution? = nil
    ) -> AsyncThrowingStream<AgentRunEvent, any Error>
}
```

`AgentRunEvent` is the streaming event type the UI consumes:

```swift
public enum AgentRunEvent: Sendable {
    case runStarted(runID: UUID)
    case stepStart(index: Int)
    case assistantStart
    case textDelta(String)
    case toolCallRequested(ToolCall)
    case toolExecutionStart(callID: String)
    case toolExecutionResult(callID: String, output: String)
    case stepEnd(index: Int)
    case checkpointSaved(checkpointID: String, step: Int)
    case awaitingApproval(AgentProposal)
    case finished(outputSummary: String?)
    case failed(reason: String)
}
```

### `ProposeTool` + `AgentApprovalSink` — human-in-the-loop

The propose-then-host-executes pattern. Side-effecting actions
(`send_email`, `create_event`, `schedule_notification`) are
**not** given as tools to the agent directly. Instead the agent
gets a single `propose_action` tool that records a structured
proposal and stops the loop:

```
agent: ... thinks ...
agent: propose_action({"kind": "send_email", "to": "...", "subject": "...", "body": "..."})
runtime: stops, emits .awaitingApproval(AgentProposal)
host: shows the user an approval card
user: taps "Send"
host: calls broker.send_email(...)   ← side effect runs ONCE, in the host
host: calls runtime.resumeStreaming(runID:, approval: .approve)
runtime: resumes the agent loop, feeds a "done — write a one-line confirmation" nudge
agent: "Sent the email to ..."
```

This is stronger than an interruptible tool call: the side
effect cannot accidentally re-run when the loop resumes, the
host controls every external state change, and the agent never
sees the action verb itself (small models can't be tricked into
fabricating a success message for a tool they never had).

`ProposeTool` validates the payload before recording it
(per-kind validators with `ProposalValidationResult`) and caps
retries — after `maxRejections = 3` malformed proposals from
the same model in the same turn, it returns a hard-stop message
so the run doesn't spin forever in a context-overflow loop.

### `CheckpointMiddleware` — pause/resume scaffolding

Fires `afterStep`, encodes the full `AgentState` (messages +
scratchpad + step counter) to `Data`, writes through the
`Checkpointer` keyed by `threadId`, and mirrors the
`(checkpointID, step)` pair onto the `AgentRunRecord`. Yields a
`.checkpointSaved` event so UIs can show progress.

> **Known limitation (0.1.x):** the checkpoint is currently used
> for audit + step-progress display, *not* for full
> state-restoration on resume. `resumeStreaming` rehydrates the
> conversation via `HistoryMiddleware` (replays messages from
> `ChatHistory`) but does not seed `AgentState.scratchpad` or
> `AgentState.stepCount` from the saved checkpoint — so a
> resumed run gets the full `maxSteps` budget fresh and loses
> any cross-step scratchpad state. For avyra's seed agents this
> is acceptable (state lives in the message history), but a host
> that relies on scratchpad should consider this before shipping.

### `AgentCatalog` + `AgentPersona` — catalogue grouping

In-memory registry the host populates at boot with curated
agents (the equivalent of `WorkflowCatalog`'s seed packs). The
catalogue is **read-only content** the user browses, runs, or
Remixes into their own `AgentStore`. Personas (`yourDay`,
`healthAndBody`, `communication`, `capture`, `focus`,
`research`) group entries for the gallery + filter pills.

---

## Host injection contract

AgentKit knows nothing about the host's MCP servers, workflow
catalogue, JS plugins, skill registry, or LLM routing. The host
supplies two closures to `boot`:

### `AgentProviderFactory`

```swift
public typealias AgentProviderFactory = @MainActor (
    _ definition: AgentDefinition
) async throws -> any LLMProvider
```

Given an `AgentDefinition`, return the `LLMProvider` that
should run it. The host's typical implementation:

1. If `definition.serverProviderID` is set, resolve to a
   `ServerLLMProvider` via the host's credential store.
2. Else if `definition.mlxModelID` is set, return an
   `MLXProvider` for that model.
3. Else fall back to `FoundationModelsProvider`.

`AgentProviders.foundationModelsOnly` is a built-in default for
hosts that don't yet have server / MLX wiring.

### `AgentExtraToolsProvider`

```swift
public typealias AgentExtraToolsProvider = @MainActor (
    _ definition: AgentDefinition,
    _ threadId: String,
    _ broker: CapabilityBroker
) async throws -> [FoundationModelsToolKit]
```

Given a definition + threadId + the broker, return any
**additional** `FoundationModelsToolKit`s the agent should
have access to. AgentKit itself wires the propose-tool and the
capability tools (resolved from `enabledCapabilities`); the
host adds:

- MCP server tools (filtered by `enabledMCPToolRefs`)
- Workflows-as-tools (filtered by `enabledWorkflowIDs`)
- JS plugin tools (filtered by `enabledPluginIDs`)
- `load_skill` + inline skill bodies (filtered by `enabledSkillIDs`)

Each tool surface is the host's responsibility because the
"how" varies (MCP transports, JS sandboxing, skill resolution
strategies). AgentKit just wants the typed kits.

---

## Quick start — for a host app

```swift
import AgentKit
import Aria
import AriaApple
import WorkflowKit

@MainActor
func bootAgents(broker: CapabilityBroker) async throws {
    let storage = try GRDBStorage()
    let store = try AgentStore.default()        // ~/Application Support/agents/
    let runStore = try AgentRunStore.default()  // ~/Application Support/agent-runs/

    await AgentRuntime.boot(
        store: store,
        runStore: runStore,
        chatHistory: storage.chatHistory,
        checkpointer: storage.checkpointer,
        broker: broker,
        providerFactory: { definition in
            // Host picks the provider — server LLM, MLX, or FoundationModels.
            if let serverID = definition.serverProviderID {
                return try await ServerLLMProvider.resolve(id: serverID)
            }
            if let mlxID = definition.mlxModelID {
                return MLXProvider(modelID: mlxID)
            }
            return FoundationModelsProvider()
        },
        extraTools: { definition, threadId, broker in
            // Host wires MCP / workflows / plugins / skills.
            var kits: [FoundationModelsToolKit] = []
            kits += try await MCPServerToolKitBuilder.makeKits(
                for: definition.enabledMCPToolRefs)
            kits += try await WorkflowToolKitBuilder.makeKits(
                workflowIDs: definition.enabledWorkflowIDs, broker: broker)
            kits += try await PluginToolKitBuilder.makeKits(
                pluginIDs: definition.enabledPluginIDs)
            if !definition.enabledSkillIDs.isEmpty {
                kits.append(LoadSkillTool.asKit(skillIDs: definition.enabledSkillIDs))
            }
            return kits
        }
    )

    // Seed catalogue content the user can browse + Remix from.
    let catalog = AgentCatalog()
    catalog.populate(with: MyAppAgentCatalog.entries())
}
```

Run an agent:

```swift
guard let runtime = AgentRuntime.shared else { return }

for try await event in runtime.runStreaming(
    agentID: agentID,
    input: .message(.user("Plan my day around the calendar.")),
    threadId: nil
) {
    switch event {
    case .runStarted(let runID): currentRunID = runID
    case .textDelta(let delta): transcript += delta
    case .awaitingApproval(let proposal): present(proposal)
    case .finished(let summary): commit(summary)
    case .failed(let reason): showError(reason)
    default: break
    }
}
```

Resume after the user approves a proposal:

```swift
// Host has already executed the side effect via the broker.
for try await event in runtime.resumeStreaming(
    runID: currentRunID,
    approval: .approve
) {
    // ... same handling as above ...
}
```

---

## Status — what's settled, what's evolving

**Settled:**
- `AgentDefinition` shape — JSON round-trip locked, conditional
  encoding, parent-id cloning, all field semantics documented.
- HITL design (propose-then-host-executes) — strong contract,
  re-run-safe, used in production by avyra.
- Streaming event surface (`AgentRunEvent`) — UI-stable, every
  event has a clear role.
- Date anchor in the system prompt — solved the
  "model invents timezones" class of bug for notification
  scheduling.
- `recommendsStrongerModel` flag — lets catalogue authors hint
  that iterative-reasoning agents work better with a server LLM
  or 8B+ MLX model.

**Evolving / known limitations:**
- **Checkpoint restoration:** see the note under
  `CheckpointMiddleware` — the checkpoint is written but the
  resume path doesn't read it back. Fix likely lands when
  `AgentMiddleware.beforeRun` gains a state-seeding hook.
- **Agent memory (RAG):** the core `Agent` supports
  `RAGMiddleware` + `FactExtractionMiddleware`, but
  `AgentCompiler` doesn't wire them in by default. Hosts that
  want agent-side memory need to extend the compiler or
  contribute a `memoryNamespace` field to `AgentDefinition`.
- **Cross-process safety:** `HistoryMiddleware` uses a per-instance
  `NSLock` to track delta persistence. Two processes (avyra + a
  hypothetical extension) writing to the same `threadId` in the
  same `ChatHistory` could interleave; the design currently
  assumes single-process ownership.
- **Logging:** AgentKit moved from `print()` to `swift-log`'s
  `Logger` in 0.1.3 — older debug taps may still reference the
  old prefixed strings.

---

## Related docs

- [`architecture.md`](architecture.md) — the six-layer Aria core
  AgentKit sits above
- [`workflowkit.md`](workflowkit.md) — the recipes-side runtime
  AgentKit's host typically also ships
- [`skills.md`](skills.md) — what a `load_skill` tool actually
  loads
- [`plugins.md`](plugins.md) — how JS plugin tools get into the
  `extraTools` kit list
- [`layers/05-agent.md`](layers/05-agent.md) — the underlying
  `Aria.Agent` loop AgentKit composes
- [`layers/04-memory.md`](layers/04-memory.md) — message history
  + checkpoints + vectors AgentKit reads
