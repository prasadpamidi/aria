# Skills

Skills are Anthropic-style instruction bundles you can ship with
your app or let users author at runtime. Each one is a `SKILL.md`
file (YAML frontmatter + markdown body) plus an optional
`manifest.json` sidecar and optional `helpers/` / `references/`
directories. The runtime model lives in WorkflowKit
(`Sources/WorkflowKit/Engine/Skills/` and `Model/Skill.swift`) and
plugs into both the chat agent and workflow LLM steps.

The skill system is host-app agnostic. You pick the on-disk
location, you decide which provider stack the rendered prompt
block flows into (FoundationModels, MLX, OpenAI, etc.), and you
wire the `load_skill` tool if your activation pattern needs it.

## Bundle layout

```
<bundlesDirectory>/
  <uuid>/
    SKILL.md            # YAML frontmatter + markdown body (canonical)
    manifest.json       # host-side metadata sidecar (optional)
    helpers/            # auxiliary files the body references (optional)
    references/         # large reference material (optional)
```

`SKILL.md` is the source of truth — the frontmatter carries the
fields the model sees, the body carries the full instructions.
`manifest.json` is a host-managed sidecar (`id`, `origin`,
`createdAt`, `enabled`, `alwaysInline`) that survives uninstall +
reinstall because it lives next to the skill. Bundles that arrive
without a manifest (e.g. a raw `SKILL.md` the user dropped via the
Files app) get a synthesised manifest tagged `origin: .imported`.

## Frontmatter fields

| Field | Type | Notes |
| --- | --- | --- |
| `id` | UUID string | Stable identifier persisted in the frontmatter so re-imports keep the same id. Synthesised on first author. |
| `name` | String | Free-text. Used in the picker UI and as the argument the model passes to `load_skill`. **Required.** |
| `description` | String | Single-paragraph summary the model sees in the system prompt. Should be specific enough that the model can tell when the skill applies. **Required.** |
| `model` | String | Optional advisory hint (e.g. `claude-3-5-sonnet`, `qwen-3-4b`). Surfaced in UI only — not enforced. Parses into `Skill.modelHint`. |
| `allowed-tools` | List of strings | Tool names the skill is allowed to invoke. Parsed + stored; not yet enforced. |
| `always-inline` | Bool | When true, the body inlines into the system prompt verbatim instead of behind `load_skill`. |
| `version` | String | Free-form, recommend semver. Round-tripped only in P0. |

The parser is a hand-rolled, Yams-free YAML reader (`SkillFrontmatterParser`)
that accepts scalar lines, inline lists (`[a, b, c]`), block lists
(`- a` indented), `#` line comments, and basic quoting. Anything
else throws `SkillError.malformedFrontmatter`.

### Example `SKILL.md`

```markdown
---
id: 9c1f4d8a-2b1f-4d4a-9a4e-7b9b5e7c2d10
name: meeting-notes
description: "Convert raw meeting transcripts into structured notes
              with decisions, action items, and open questions."
model: claude-3-5-sonnet
allowed-tools: [load_skill]
always-inline: false
version: 1.2.0
---

# Meeting Notes

When the user supplies a transcript, respond with three sections:

## Decisions
- One bullet per decision made.
- Quote the wording used when the decision was stated.

## Action items
- Owner — Action — Due date (if mentioned).

## Open questions
- One bullet per unresolved question. Mark blocker status if obvious.

Prefer the original speaker's wording over paraphrase. If a section
has no entries, write "_None._" rather than omitting the heading.
```

## SkillProvider

`SkillProvider` is the in-memory mirror over a `bundlesDirectory`.
It's `@MainActor @Observable` so SwiftUI views can bind to it
directly. The recommended pattern is one provider per process —
instantiate it at app launch, inject through the environment, and
let mutations ripple through the `@Observable` surface.

```swift
@MainActor
@Observable
public final class SkillProvider {
    public init(bundlesDirectory: URL)
    public let bundlesDirectory: URL

    public private(set) var skills: [Skill]
    public private(set) var errors: [LoadError]

    public func skill(for id: UUID) -> Skill?
    public func enabledSkills() -> [Skill]
    public func loadBody(for id: UUID) throws -> String

    @discardableResult
    public func authorNew(
        name: String,
        description: String,
        body: String,
        modelHint: String? = nil,
        allowedTools: [String] = [],
        alwaysInline: Bool = false,
        version: String? = nil
    ) throws -> Skill

    public func update(id: UUID, …) throws
    public func setEnabled(_ enabled: Bool, for id: UUID) throws
    public func delete(id: UUID) throws
    public func reload()
}
```

`bundlesDirectory` is public so host code can compose paths off it
without re-deriving — import sheets, Finder-reveal actions,
zip-export pipelines all need it. The provider scans the directory
on init and after every mutation; load failures land on `errors`
rather than throwing, so one malformed bundle doesn't blank the
list.

## Activation paths

Two patterns ship out of the box, and you can mix them per skill
via the `always-inline` flag.

### 1. Always-inline

For short personas, style guides, or domain-specific glossaries
where the body is cheap to include and the round-trip cost of
`load_skill` doesn't pay for itself. Set `always-inline: true` in
the frontmatter and the body inlines into the system prompt.

### 2. Load-on-demand

Default. Only the skill's `name + description` appears in the
system prompt (in a "Skills (load on demand)" catalogue). When the
model decides the skill applies, it calls a host-wired
`load_skill(name:)` tool, the host reads the body off disk via
`SkillProvider.loadBody(for:)`, and returns it as the tool result.

The host owns the `load_skill` tool. On Apple platforms, the
canonical adapter is Avyra's `LoadSkillTool` for FoundationModels;
for other providers, register an equivalent tool that takes a
single `name` argument and returns the markdown body. The
catalogue line in the system prompt tells the model to use the
skill's *exact* `name`.

## `SkillPromptBuilder`

`SkillPromptBuilder.systemPromptBlock(provider:allowedSkillIDs:)`
renders the prompt augmentation. The output is two sections:

1. `--- Skills (inline) ---` followed by the body of every
   always-inline skill.
2. `--- Skills (load on demand) ---` followed by a one-line
   catalogue entry (`- name — description`) per non-inline skill.

The builder returns an empty string when no skills are enabled —
callers can append unconditionally without polluting the prompt.
Pass an `allowedSkillIDs: Set<UUID>?` to honour per-scope
overrides; pass `nil` to use the globally-enabled set.

```swift
@MainActor
let provider = SkillProvider(bundlesDirectory: appSupport.appendingPathComponent("skills"))

let systemBlock = SkillPromptBuilder.systemPromptBlock(provider: provider)

let agent = Agent(config: AgentConfig(
    provider: FoundationModelsProvider(typedTools: [loadSkillToolFactory]),
    tools: [loadSkillAnyTool],
    systemPrompt: """
    You are a helpful assistant.

    \(systemBlock)
    """,
    threadId: "main"
))
```

## SkillOverridesStore

Skills are globally enabled in your Settings UI, but users often
want to override that for one scope — this chat thread, this
workflow run, this editor session. `SkillOverridesStore` is the
per-scope override layer.

Scope is identified by an opaque string key, so the same store
backs both per-thread and per-workflow overrides without a second
type. Two override flavours, stored asymmetrically:

- **`disabled[scope]`** — skills the user toggled off for this
  scope. Subtracted from the effective set.
- **`extra[scope]`** — skills the user manually attached for this
  scope. Added to the effective set even if globally disabled.

Effective set:

```
effective = (globalEnabledIDs ∪ extra[scope]) − disabled[scope]
```

`effectiveSkillIDs(for:globalEnabledIDs:)` is the read API the
prompt builder calls. `setEnabled(_:skillID:for:globallyEnabled:)`
is the write API the chip-rail UI calls; it stores asymmetrically
so reverting to the global default clears the override rather than
persisting redundant state. The store persists to a single JSON
file at the URL you pass to `init` and is typically a process-wide
singleton.

## Workflow integration

For workflow LLM steps, `Workflow.enabledSkillIDs` declares the
workflow-wide skill set, and each `LLMStep` can layer on
`extraSkillIDs` or hide via `disabledSkillIDs`.
`WorkflowSkillSet.effective(workflow:step:)` computes the
per-step set; `WorkflowSkillResolver` (a `@Sendable (Set<UUID>)
async -> WorkflowSkillBlock` the host injects) expands ids to a
prepared markdown block. Workflow steps don't run an agent loop,
so progressive disclosure isn't available — every requested
skill's description + body inlines into the step's system prompt
at compile time.

See [`docs/workflowkit.md`](workflowkit.md) for the workflow shape
and the rest of the compiler injection seams. The high-level
`Aria` architecture is in [`docs/architecture.md`](architecture.md)
and the SDK overview is in the
[main README](../README.md).
