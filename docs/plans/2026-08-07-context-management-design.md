# Context management, agent harness, and memory — review and redesign

**Status:** proposed
**Date:** 2026-08-07
**Affects:** `Aria` (core), `AriaMLX`, and every consumer — Avyra, Niora, future apps

## Why this exists

A user on an iPhone 15 Pro reported bad chat responses from an on-device
1.2B model. Three exported session bundles showed the same failure: a
four-word greeting ("How is it going?") answered with a fabricated user
profile.

The immediate cause turned out to be prompt construction, not model
quality. But investigating it surfaced a structural problem: **Aria has
no working notion of a context budget.** The component named for the job
cannot see most of what it is supposed to budget.

Measured from a real session:

| | tokens |
|---|---|
| What `HistoryWindowMiddleware` was budgeting | ~12 |
| What the provider actually received | 3,698 |

The middleware was operating on 0.3% of the real context and reporting
success.

## Findings

### F1 — The context budget is blind to most of the context

`HistoryWindowMiddleware(maxTokens:)` documents itself as capping the
"total token budget across ALL messages (system + history)". It only
ever inspects `state.messages`.

Two of the three real contributors never appear there:

- `config.systemPrompt` is prepended in
  `AgentStep.buildProviderMessages`, which runs *after* all middleware.
- Tool definitions are passed to `provider.stream(messages:tools:)` and
  serialized by the provider's chat template. They never enter
  `state.messages` in any form.

The middleware is structurally incapable of seeing them. This is a
placement bug, not a logic bug — no amount of fixing the algorithm helps
while it runs where it runs.

### F2 — Nothing knows the model's context limit

`ProviderCapabilities.maxContextTokens` is populated by every provider
and read by nobody. A repository-wide search returns only assignments.

Worse, the value would be misleading if used. `AriaMLX` populates it
from the model's `config.json`, so LFM2.5 reports 128,000 — its trained
maximum, not a number achievable on a phone, where KV cache is bounded
by memory long before the model's architecture is.

There is no concept of a *usable* window anywhere in the system.

### F3 — The tool surface is unbounded and unconditioned

No cap exists on tool count in any consumer's chat path. Every
registered tool is serialized into every request regardless of relevance
to the turn.

In Avyra specifically, the Settings → Tools screen gates six built-in
tools, while JS plugins and MCP server tools are appended
unconditionally and cannot be disabled from that screen at all. A user
who disables everything the UI offers still ships ~3,500 tokens of tool
schemas per turn.

The cost is also invisible: connecting one MCP server silently adds
thousands of tokens to every subsequent turn, with no indication
anywhere in the product.

### F4 — Reliability is computed, displayed, then ignored

`MLXModelReliability` documents that low-reliability models lose access
to proposal-style tools. Consumers treat the tier as advisory. A 1.2B
model receives an identical tool surface to a 9B.

### F5 — Memory policy is decoupled from memory tooling

In Avyra, the memory *policy text* is gated on `settings.memoryEnabled`
while the `remember_fact` *tool* is gated on
`settings.rememberToolEnabled`. The two settings are independent, so the
model can be instructed at length on when to call a tool it does not
have.

Separately, `RAGMiddleware` renders its top-K matches into a
`Message.system(...)` of unbounded length and splices it into state. It
is a second component making context decisions with no budget.

Empirically, the policy's field enumeration — "name, role, preferences,
goals, constraints, relationships" — was reproduced as *response
content* in three of three observed sessions. Small models treat a
densely-negated policy block as a template to fill rather than a rule to
obey.

### F6 — Token counting is a 4-characters-per-token heuristic

Adequate for prose. Materially wrong for JSON schemas, which is exactly
the content we most need to count.

### F7 — The defect is not app-specific

Niora reproduces it independently at
`iOS/Niora/LLMs/Aria/AriaContext.swift:107`, using the same
`HistoryWindowMiddleware(maxTurns: 16, maxTokens: 4000)` with the same
blindness. Any future consumer wiring the documented pattern inherits
it. **The fix belongs in Aria, not in the apps.**

## Design

### Principle: one component decides

Context allocation happens in exactly one place, and that place can see
everything. Today the decision is split between `HistoryWindowMiddleware`
(sees history), `RAGMiddleware` (injects memory), the consumer's prompt
builder (writes the system prompt), and the provider (serializes tools).
None of them can see the total.

### Relocation

Budget enforcement moves from middleware to **step assembly** —
`AgentStep.buildProviderMessages` — the only point where system prompt,
tools, and messages are simultaneously in scope.

```swift
public struct ContextBudget: Sendable {
    public let total: Int              // usable window, not advertised
    public let reservedForOutput: Int
    public let maxTools: Int?          // nil = unbounded
    public var available: Int { total - reservedForOutput }
}

public protocol ContextAssembler: Sendable {
    func assemble(
        systemPrompt: String?,
        tools: [ToolDefinition],
        messages: [Message],
        state: AgentState,
        budget: ContextBudget
    ) async -> AssembledContext
}

public struct AssembledContext: Sendable {
    public let messages: [Message]
    public let tools: [ToolDefinition]
    public let allocation: ContextAllocation   // for observability
}
```

The default implementation allocates in priority order: system prompt,
tools, recalled memory, then history newest-first. It reports what it
dropped rather than dropping silently.

### The usable window

`ProviderCapabilities.maxContextTokens` stays as the honestly-reported
advertised value. A sibling `usableContextTokens` is added for what is
actually achievable.

For MLX this is a hand-checked per-entry value on
`MLXModelCapabilities`, consistent with how the catalog already carries
curated flags rather than inferring them. Starting point for
LFM2.5-1.2B: **4,096**, to be moved by evidence rather than by
preference.

### Token counting

`TokenCounter` becomes a protocol. The 4-chars heuristic remains the
default for message text; tool schemas get a schema-aware path, since
JSON tokenizes considerably worse than prose and tools dominate the
budget.

### Tool selection

```swift
public protocol ToolSelector: Sendable {
    func select(from tools: [ToolDefinition],
                query: String,
                limit: Int) async -> [ToolDefinition]
}
```

`LexicalToolSelector` is the default: token overlap with IDF weighting
against each tool's name and description. No new dependencies.
`ColBERTToolSelector` conforms later without changing any call site.

Two correctness requirements that outrank ranking quality:

1. **Stickiness.** The assembler unions freshly-selected tools with
   every tool already invoked during this run, read from `AgentState`.
   Without this, a tool called in step *N* vanishes in step *N+1* and
   its result becomes unresolvable — producing intermittent multi-step
   failures that are painful to diagnose.

2. **Pinning.** `pinnedToolNames: Set<String>` always survives
   selection. Gateway tools such as `load_skill` are self-defeating to
   retrieve away.

`maxTools` is a plain integer on the budget. Aria core does not know
about `MLXModelReliability` — that is an `AriaMLX` concept, and core
must not depend on it. The **consumer** maps tier to number
(`.low` → 5, `.medium` → 12, `.high` → nil). This makes F4's tier
load-bearing without leaking MLX types into core.

### Memory

**Guidance moves onto the tool.** `ToolDefinition` gains an optional
`promptGuidance: String?`. The assembler emits guidance only for tools
that survived selection.

This makes F5 unrepresentable: policy describing an absent tool becomes
impossible by construction, and guidance for unselected tools costs
nothing. Retrieval and instructions stay in lockstep automatically.

**RAG proposes, the assembler disposes.** `RAGMiddleware` attaches
ranked candidates to `AgentState` instead of rendering a final system
message. The assembler renders as many as its memory allocation permits,
in relevance order. One authority, and a pathologically long memory can
no longer crowd out the conversation.

**Phrasing.** Guidance is rewritten in positive, imperative form and
kept short. For low-capability profiles the assembler may reduce it to a
single line. The current four sentences of negation are precisely what
sub-2B models fail at, by Aria's own documentation.

**Embeddings.** `Embedder` is already a protocol, so
LFM2.5-Embedding-350M is a conforming implementation once
`MLXEmbedders` supports non-BERT architectures. Note the migration:
swapping embedders invalidates every stored vector, which is why
`Embedder.modelIdentifier` exists. A re-embed path must be designed
before anyone flips the default — not after.

## Migration

**Everything is additive and opt-in.** `AgentConfig` gains an optional
`contextAssembler`. When `nil`, behavior is byte-identical to today.
`HistoryWindowMiddleware` remains public and functional, marked
deprecated only once the assembler path has proven out.

This matters because consumers pin Aria by `exactVersion`. A breaking
change here would be self-inflicted.

Order:

1. **Aria core** — `ContextBudget`, `ContextAssembler` + default,
   `TokenCounter`, `ToolSelector` + lexical, `ToolDefinition.promptGuidance`.
2. **AriaMLX** — `usableContextTokens` on catalog entries.
3. **Aria core** — RAG candidates in state, behind the assembler path.
4. **Avyra** — adopt the assembler; map reliability to `maxTools`; move
   the memory policy onto `RememberTool`; delete the hand-written policy
   block; gate JS/MCP tools from the Tools screen.
5. **Niora** — adopt at `AriaContext.swift`.
6. **Later** — `ColBERTToolSelector`, LFM2.5 embedder, `find_tools`
   escape hatch.

## Testing

This class of bug survived because **nothing ever measured the assembled
prompt.** The test strategy follows directly from that.

Keystone test: a golden fixture asserting the real assembled token count
for a known agent configuration. This single test would have caught F1
on day one.

Supporting:

- Property: assembled context never exceeds `budget.available`.
- Stickiness: a tool invoked in step *N* is present in step *N+1*.
- Pinning: pinned tools survive selection at any `maxTools`.
- Guidance: appears only for tools that survived selection.
- Selection: a relevant tool outranks an irrelevant one.
- Regression: `contextAssembler == nil` reproduces current output
  exactly.

## Observability

The assembler emits its `ContextAllocation` — system / tools / memory /
history token counts, plus what was dropped — into the session bundle.

This closes F3's second half. The investigation behind this document
required reading source across three repositories to answer "why is this
prompt 5,474 tokens?". With the allocation recorded, that becomes a
table in the exported bundle.

## Risks

- **Retrieval misses a needed tool.** Mitigated later by a pinned
  `find_tools(query:)`; the pinning mechanism is designed now so the
  escape hatch is possible without rework.
- **`usableContextTokens` is initially a judgment call.** Start
  conservative, move on measurement.
- **Two consumers to migrate**, both on pinned versions. Addressed by
  making adoption opt-in.

## Out of scope

- PII detection / redaction. It shares the encoder dependency with the
  embedding work but is a privacy feature, not context management.
  Bundling would blur both designs.
- Per-model prompt templating beyond guidance length.
- Device RAM gating for model selection — a real and separate defect
  (`recommendedRAMGigabytes` is displayed but never enforced), tracked
  independently.
