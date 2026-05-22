# Avyra Skills + Server-Provider Tool Calling — Design

> Status: design. Not yet implemented.
> Companion docs:
> - `2026-05-20-avyra-workflows-design.md` (workflow runtime)
> - `2026-05-20-avyra-workflows-p0-plan.md` (P0 implementation plan)

## 1. Why

Two related capabilities are missing that block agentic use cases the user has flagged:

1. **Anthropic-style Skills** — user-installable instruction bundles that give the model new behaviours without requiring code. Skills are how a non-engineer extends an agent's competence (e.g. "always format meeting notes like this," "when asked for a recipe, follow this rubric").
2. **Tool calling for server LLM providers** (OpenAI / Anthropic / Gemini). Today the chat-side `ServerChatLLMProvider` advertises `supportsToolUse = false` so MCP tools, native tools, JS plugin tools, and skill activation are all **off** when a server provider is the active chat model. Workflow LLM steps routed to a server provider have the same limitation.

These ship together because skills are best activated via tool calling (Anthropic's published pattern), and the work to enable tool calls on server providers is the prerequisite for both skills AND MCP to function under server-provider chat.

## 2. Skills primer

A **skill** is a folder bundle whose root contains a `SKILL.md` file. The structure Anthropic uses:

```
my-skill/
  SKILL.md
  helpers/
    extract_dates.py
  references/
    rubric.md
```

`SKILL.md` carries YAML frontmatter + a markdown body:

```markdown
---
name: meeting-notes
description: Format meeting notes with attendees, decisions, and action items. Use when the user pastes meeting transcripts or asks for "structured notes".
model: claude-3-5-sonnet   # optional; advisory hint
allowed-tools: [Read, Write] # optional; for code-executing agents
---

# Meeting notes skill

When the user asks you to format meeting notes:

1. Extract attendees from the first speaker tags.
2. Pull decisions from sentences containing "we decided" / "let's".
3. Pull action items from "I'll", "John will", "TODO" patterns.
4. Emit using the rubric in `references/rubric.md`.

## Examples
…
```

The Anthropic convention is **progressive disclosure**: only the frontmatter (`name` + `description`) sits in the system prompt by default — that paragraph teaches the model when the skill is relevant. The full body is fetched on demand when the model decides to invoke the skill. Helper files (`./helpers/extract_dates.py`, `./references/rubric.md`) are accessible to the model only after the skill body has been loaded, and only as the body's instructions direct.

This pattern matters for Avyra because:
- A user can have many skills installed; we can't put every body in the system prompt.
- On-device models have small context windows; we need to load selectively.
- The user owns the skill files — we shouldn't ship them encoded as app updates.

## 3. Avyra-side architecture

### 3.1 Data model

```swift
// In Sources/WorkflowKit/Model/Skill.swift
public struct Skill: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID            // stable across renames (see open question #1)
    public var name: String        // human-readable; can rename
    public var description: String // single paragraph, what the model sees up front
    public var modelHint: String?  // advisory hint from frontmatter
    public var allowedTools: [String] // tool names this skill can use
    public var alwaysInline: Bool  // when true, body lives in system prompt (no load_skill needed)
    public var origin: Origin
    public var bundleRelativePath: String // resolves under avyra-skills/
    public var version: String?    // semver-ish, for future update checks
    public var createdAt: Date
    public var updatedAt: Date

    public enum Origin: String, Codable, Sendable {
        case authored, imported, downloaded
    }
}

public struct SkillBundle: Sendable {
    public let skill: Skill
    public let body: String        // loaded on demand, not always-present
    public let helperFileURLs: [URL]
}
```

Lives in `Sources/WorkflowKit/Model/` because skills are referenced by the workflow engine (LLM steps), not just the chat. Same layering rationale as `Credential`, `ServerLLMProvider`, `MCPToolDescriptor`.

### 3.2 Storage

- `Application Support/avyra-skills/{skill-id-uuid}/` — one directory per skill, mirroring the JS plugin pattern (`avyra-tools/`).
- `SKILL.md` at the root, helpers in subdirectories.
- The store keeps the parsed `Skill` array in memory + a metadata cache; the body is reloaded from disk on demand to keep the in-memory footprint bounded for users with many skills.
- Bundle format for import / export: `.avyra-skill` zip of the directory contents. Same shape as `.avyra-tool`.

### 3.3 Frontmatter parser

We need a small YAML reader for the frontmatter block. Options:

- **Yams** (popular Swift YAML package). Adds a dep.
- **Hand-rolled scalar-only parser**. SKILL.md frontmatter is a flat dictionary of string/array values — no nesting, no anchors. We can write this in ~80 lines and avoid the dep.

Recommendation: hand-rolled. Keeps the dep graph tight. Strict on unsupported features (multi-line scalars, anchors, references); permissive on common constructs (quoted strings, lists, comments).

### 3.4 Authoring / import / download

Settings → Skills (new screen, mirrors Settings → Tools):

- **List** — shows every installed skill with name + description + enabled toggle + origin badge. Swipe to delete.
- **Author** — pushes a Runestone-backed markdown editor (we already use Runestone for JS plugin authoring). Save commits a new entry under `avyra-skills/{uuid}/SKILL.md`.
- **Import** — document picker for `.avyra-skill` zips. Decompress to `avyra-skills/{uuid}/`. Surface frontmatter errors inline.
- **Download from URL** — paste a URL pointing to either a raw SKILL.md or a `.avyra-skill` zip. Fetch via URLSession, save to the same directory.
- **Each row** pushes a detail screen with the rendered body (read-only) + editable name/description/enabled/alwaysInline + a button to re-export as a `.avyra-skill` bundle for sharing.

### 3.5 The provider

```swift
@MainActor
@Observable
public final class SkillProvider {
    public private(set) var skills: [Skill]
    public func skill(for id: UUID) -> Skill?
    public func enabledSkills() -> [Skill]
    public func install(from zipURL: URL) async throws -> Skill
    public func authorNew(name: String, description: String, body: String) throws -> Skill
    public func update(_ skill: Skill)
    public func delete(_ id: UUID)
    public func loadBody(for id: UUID) throws -> String
}
```

Same lifecycle pattern as `JSToolProvider` (which is `@Observable` + `@MainActor`). Injected via `@Environment` at app root.

### 3.6 Activation strategy — primary path

**Tool-call activation.** This is Anthropic's published pattern and the right default. The agent's tool list includes a synthetic `load_skill` tool. The model sees skill descriptions in the system prompt; when it decides a skill applies, it calls `load_skill(name)` and gets the body back as the tool result, then uses it on the next reasoning step.

```swift
// Tool definition
ToolDefinition(
    name: "load_skill",
    description: """
        Load the full instructions for a skill. Call this when a skill's
        description matches the user's task. Returns the skill's markdown body
        which you should then follow.
        """,
    inputSchema: .object(
        properties: ["name": .string(description: "The skill's `name` field")],
        required: ["name"]
    ),
    outputSchema: nil
)
```

System prompt augmentation (built fresh per turn from `SkillProvider.enabledSkills`):

```
You have access to the following skills. When a skill's description matches the
user's request, call the `load_skill` tool with that skill's name to fetch its
full instructions.

Skills:
- meeting-notes — Format meeting notes with attendees, decisions, and action items.
- recipe-rubric — Format recipes with ingredients table, steps, prep + cook times.
- code-review — Walk through code review with security, readability, and test coverage.
```

The system prompt cost stays bounded — one line per skill — even for users with dozens of skills.

### 3.7 Activation strategy — secondary path: always-inline

Some skills are tiny (a personality, a formatting preference) and the user wants the model to always carry them without a round-trip. Per-skill `alwaysInline: Bool` flag (default `false`). When `true`, the skill's body is appended to the system prompt verbatim instead of just the description. The user opts into this in the skill's edit screen.

Use cases:
- Persona: "You are a curt scientist."
- Style: "Always use British spelling."
- Domain: "Avyra is a fitness-focused workflow assistant. Frame examples around fitness when ambiguous."

### 3.8 Activation strategy — rejected: semantic match

Embedding skill descriptions + top-K match against the user message looks attractive but has hidden costs:
- Need an embedder for every chat turn.
- Wrong matches lead to silently wrong behaviour.
- The user has no way to override.

Tool-call activation gives the model agency + audit trail (the user sees "Loaded skill: meeting-notes" in the run UI). Skip this option.

## 4. Integration points

### 4.1 Chat

Settings → Skills holds the master enable/disable per skill. The chat composer gets a per-thread chip rail (similar to attachment chips) showing which skills are currently exposed to this thread — defaults to the user's global enabled set, can be narrowed for a specific conversation.

`ChatScreen.makeAgent` reads:
- `SkillProvider.enabledSkills` (intersected with the chat's per-thread override set if any).
- Builds the augmented system prompt block.
- Constructs the `LoadSkillTool` (an `AnyTool` + FM-routable kit, same shape as MCP / JS plugin tools).
- Appends to the existing `kits` array.

The agent build path doesn't change otherwise. Tools advertise via `FoundationModelsToolKit.factory` for Apple Intelligence and `anyTool` for MLX. Skills work for both without further changes.

### 4.2 Workflows

**Workflow-level enablement** (set on the `Workflow`):

```swift
public struct Workflow: ... {
    public var enabledSkillIDs: Set<UUID> // applies to every LLM step in the workflow
}
```

**Per-step enablement** (set on individual `LLMStep`):

```swift
public struct LLMStep: ... {
    public var extraSkillIDs: Set<UUID>   // union'd with the workflow's
    public var disabledSkillIDs: Set<UUID> // subtracted (precedence over the workflow default)
}
```

The compiler augments the prompt for each LLM step with the effective skill set's descriptions. The `load_skill` tool is added to the step's tool surface. Identical pattern to chat.

For background-context workflows (Shortcuts / Siri / AppIntents), skills work just as well as built-in tools — no network required, no credential required. The skill body lives on-device.

### 4.3 Workflow editor — skill picker

The workflow editor gets a "Skills" section in the workflow's settings sheet (mirrors how `Triggers`, `Input schema`, `Output schema` work). For an individual LLM step, the editor's existing Model picker page gains a "Skills" subsection — tap to enter a multi-select picker (`SkillPickerView`, mirrors `LLMStepModelPickerView`). Selecting toggles into `extraSkillIDs` / `disabledSkillIDs`.

## 5. Server-provider tool calling — the prerequisite work

### 5.1 Why it blocks both skills + MCP

Today `ServerChatLLMProvider`:
- Implements `Aria.LLMProvider`.
- Advertises `supportsToolUse: false`.
- Squashes the conversation into one prompt, sends to vendor, yields the reply as a single `textDelta` event.

The agent skips tool wiring entirely when `supportsToolUse` is `false`. So when a server provider is the active chat model:
- MCP tools — not exposed.
- JS plugin tools — not exposed.
- Native built-ins (`Remember`, `Calculator`, HTTP, etc.) — not exposed.
- The `load_skill` tool — not exposed → **skills don't work on server providers**.

Workflow LLM steps that route to a server provider hit the same fence: no tools, no skills.

The fix is one piece of work — implement vendor-specific tool calling in the chat-side server provider — and unlocks four feature classes at once.

### 5.2 Per-vendor protocol survey

Each vendor exposes tool calling differently. The implementation has to map Aria's protocol-agnostic `ToolDefinition` / `ToolCall` / `ToolResult` shape onto each vendor's wire format.

#### 5.2.1 OpenAI Chat Completions

Request shape (`/chat/completions`):
```json
{
  "model": "gpt-4o-mini",
  "messages": [
    {"role": "system", "content": "..."},
    {"role": "user", "content": "..."}
  ],
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "load_skill",
        "description": "...",
        "parameters": { /* JSONSchema */ }
      }
    }
  ],
  "tool_choice": "auto"
}
```

Response shape (when the model calls a tool):
```json
{
  "choices": [{
    "message": {
      "role": "assistant",
      "content": null,
      "tool_calls": [{
        "id": "call_abc",
        "type": "function",
        "function": {"name": "load_skill", "arguments": "{\"name\":\"meeting-notes\"}"}
      }]
    },
    "finish_reason": "tool_calls"
  }]
}
```

Tool result for the next turn:
```json
{"role": "tool", "tool_call_id": "call_abc", "content": "<skill body>"}
```

Streaming via SSE (`stream: true`) — chunks carry `delta.tool_calls` arrays.

#### 5.2.2 Anthropic Messages

Request shape (`/messages`):
```json
{
  "model": "claude-3-5-sonnet-latest",
  "max_tokens": 4096,
  "system": "...",
  "messages": [{"role": "user", "content": "..."}],
  "tools": [{
    "name": "load_skill",
    "description": "...",
    "input_schema": { /* JSONSchema */ }
  }]
}
```

Response shape (when the model calls a tool):
```json
{
  "stop_reason": "tool_use",
  "content": [
    {"type": "text", "text": "I'll load that skill."},
    {"type": "tool_use", "id": "toolu_abc", "name": "load_skill", "input": {"name": "meeting-notes"}}
  ]
}
```

Tool result for the next turn (appended to messages):
```json
{
  "role": "user",
  "content": [
    {"type": "tool_result", "tool_use_id": "toolu_abc", "content": "<skill body>"}
  ]
}
```

Streaming via SSE — `content_block_start` / `content_block_delta` / `content_block_stop` for each block.

#### 5.2.3 Gemini

Request shape (`/models/{model}:generateContent`):
```json
{
  "contents": [{"role": "user", "parts": [{"text": "..."}]}],
  "tools": [{
    "functionDeclarations": [{
      "name": "load_skill",
      "description": "...",
      "parameters": { /* JSONSchema, with type names in PascalCase */ }
    }]
  }]
}
```

Response shape:
```json
{
  "candidates": [{
    "content": {
      "parts": [{"functionCall": {"name": "load_skill", "args": {"name": "meeting-notes"}}}]
    },
    "finishReason": "STOP"
  }]
}
```

Tool result for the next turn:
```json
{"role": "function", "parts": [{"functionResponse": {"name": "load_skill", "response": {"result": "<skill body>"}}}]}
```

Streaming via `:streamGenerateContent` — SSE-style.

#### 5.2.4 Cross-vendor abstraction

Each vendor has the same logical shape:

1. Send `messages + tools` (with optional `system`).
2. Receive either text OR `tool_calls` (sometimes both).
3. If tool_calls present, execute them and submit results in the next turn.
4. Repeat until pure text response.

The differences are wire-format details. We build per-vendor mappers that translate between Aria's `Message` / `ToolDefinition` / `ToolCall` and the vendor JSON shape.

### 5.3 Implementation: split the chat client from the workflow client

Right now we have **three** WorkflowLLM clients (`OpenAI…`, `Anthropic…`, `Gemini…`) under `Sources/WorkflowKit/Engine/ServerLLM/` and **one** chat adapter `ServerChatLLMProvider` that delegates to them via `generate(prompt:) -> String`.

The chat adapter needs to be split: it speaks the **full** Aria `LLMProvider` protocol including tools + streaming. The WorkflowLLM clients keep their text-only `generate` shape for workflow LLM steps that don't need tools.

Proposed structure:

```
Sources/WorkflowKit/Engine/ServerLLM/
  Workflow/                 # existing, text-only clients used by LLMStep
    OpenAIWorkflowLLMProvider.swift
    AnthropicWorkflowLLMProvider.swift
    GeminiWorkflowLLMProvider.swift

  Chat/                     # new, full LLMProvider conformers for chat
    OpenAIChatProvider.swift
    AnthropicChatProvider.swift
    GeminiChatProvider.swift
    ServerChatStreaming.swift   # SSE parser shared across vendors

  Shared/
    ServerLLMError.swift              # already there
    JSONSchemaToVendorParameters.swift # schema → vendor-shaped tool parameters
    VendorRequest.swift               # shared request types
```

`ServerChatLLMProvider` (in the app) becomes a thin router: given an active `ServerLLMProvider`, instantiate the right chat client and forward.

### 5.4 Workflow LLM-step tool support

Once chat-side tool calling lands, the workflow LLM step also gets tools when routed to a server provider. The engine already wires tools to LLM steps via the agent's tool surface — we just need the provider to advertise `supportsToolUse: true`.

### 5.5 What changes for skills, MCP, and built-ins

All four use the existing `[AnyTool]` array on `AgentConfig`. No changes needed to skills code, MCP code, or built-in tools — once the chat adapter speaks tools, they all flow through.

The single "Tools and image attachments are off for remote models" notice in the chat composer comes off (or gets narrowed to "Streaming is non-streaming for remote models" until streaming lands too).

## 6. Implementation phases

Sequenced for minimal risk; each phase ships independently green.

### Phase 1 — Skill data model + storage (1 day)
- `Sources/WorkflowKit/Model/Skill.swift` — model.
- `Sources/WorkflowKit/Engine/Skills/SkillBundle.swift` — disk reader (frontmatter parser + body loader).
- Tests: round-trip, malformed frontmatter, missing fields.
- Build green; no UI yet.

### Phase 2 — App-side store + Settings list (1–2 days)
- `Apps/AvyraApp/Avyra/Skills/SkillProvider.swift` — `@Observable` store.
- `Apps/AvyraApp/Avyra/Skills/SkillsListScreen.swift` — Settings entry; list + enabled toggles + delete.
- `Apps/AvyraApp/Avyra/Skills/SkillImportButton.swift` — document picker for `.avyra-skill` zips.
- Settings → Skills row in `SettingsScreen`.

### Phase 3 — Author + download (1–2 days)
- Runestone-backed `SkillAuthoringScreen.swift` for in-app authoring.
- "Download from URL" sheet calling URLSession.
- Per-skill edit screen with always-inline toggle.

### Phase 4 — Chat integration (1 day)
- `LoadSkillTool` (`AnyTool` + FM kit factory mirroring the MCP kit builder pattern).
- `ChatScreen.makeAgent` appends skill descriptions to the system prompt + the `LoadSkillTool` to the tool list.
- Inline-skills concatenate body into system prompt.

### Phase 5 — Workflow integration (1–2 days)
- `Workflow.enabledSkillIDs` + `LLMStep.extraSkillIDs` / `disabledSkillIDs` fields.
- Compiler augments LLM step prompts with skill descriptions, adds `LoadSkillTool` to step's tool surface.
- Workflow editor: Skills picker at workflow level + per-step.

### Phase 6 — Server-provider tool calling (1 week)
- File reorg: split chat-vs-workflow server LLM clients.
- `OpenAIChatProvider` — full streaming + tools.
- `AnthropicChatProvider` — full streaming + tools.
- `GeminiChatProvider` — full streaming + tools.
- Shared SSE parser.
- `ServerChatLLMProvider` becomes a thin router.
- Remove the "tools off for remote models" notice.

Phase 6 is the long one. Phases 1–5 ship skills on Apple Intelligence + MLX immediately, even before Phase 6.

## 7. Open questions

1. **Skill id stability vs renames** — slug from name (rename changes id, references break) or UUID (renames stable, id is opaque). **Recommendation**: UUID stored in frontmatter as `id:`, so renames don't break references.
2. **Helper file execution** — should `helpers/extract_dates.py` actually run when the model invokes a skill that references it? Anthropic's CLI agents do execute scripts; Avyra is mobile and Python isn't available. **Recommendation for P0**: helpers are reference-only (text the model can read but not execute). A future "skill scripting" surface could route through the JS plugin runtime.
3. **`allowed-tools` frontmatter field** — Anthropic skills declare which tools the skill is allowed to use. We could honour this by filtering the tool list when a skill is active. **Recommendation for P0**: parse + store but don't enforce; revisit when we have user data on misuse.
4. **Skill sharing format** — `.avyra-skill` zip vs. a hosted marketplace. **Recommendation for P0**: zip files via Files app + "Download from URL." A marketplace is a much bigger product surface.
5. **Per-conversation skill overrides** — chip rail in composer vs. just relying on Settings → Skills toggles. **Recommendation**: ship Settings-level toggles first, evaluate need for per-conversation override.
6. **Skill versioning** — `version:` field for re-downloading updates from a URL? **Recommendation for P0**: include the field, do nothing with it. Skill manager checks for updates when polled by the user.

## 8. Out of scope (deliberately)

- **Skill marketplace** — directory + ratings + categories. Could be a Phase 7 product feature.
- **Skill chaining inside one turn** — model loading multiple skills in sequence. The current design supports this naturally via the agent loop; no special handling needed.
- **Skill telemetry** — track which skills are activated, by what prompt. Could land alongside the tracing recorder.
- **Inter-skill dependencies** — one skill `extends:` another. Anthropic doesn't support this; we shouldn't invent it.

## 9. Decision summary

- Skill data model + storage live in `WorkflowKit`; UI + store in the app target.
- **Tool-call activation** as the primary path (`load_skill(name)` tool), with **always-inline** as an opt-in for personality / style skills.
- Skills are first-class for **Apple Intelligence + MLX** as soon as Phases 1–5 land.
- **Server provider tool calling** (Phase 6) is the unlock for skills + MCP + built-ins + JS plugins on OpenAI / Anthropic / Gemini chat. It's the highest-leverage piece of work because one implementation enables four feature classes.

If approved, Phases 1–4 (~5 days) ship a usable end-to-end skill experience for the on-device chat. Phases 5–6 follow.
