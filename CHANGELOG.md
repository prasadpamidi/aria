# Changelog

All notable changes to Aria are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and Aria adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.4] - 2026-05-26

### Added

- **WorkflowKit: typed structured-output dispatch for `LLMStep`.**
  `WorkflowLLMProvider` now has a `generateStructured(prompt:hint:maxTokens:schemaID:)`
  entry point. The compiler routes an LLM step through it whenever
  `LLMStep.structuredOutputSchema` is set to a non-empty id; otherwise the
  existing `generate(...)` text path is unchanged. The default
  `generateStructured` impl falls back to text + lenient JSON parse (strips
  markdown code fences), so providers that haven't adopted native schema
  support keep working without code changes. Providers with native
  structured-output APIs (Apple FoundationModels' `session.respond(to:
  generating:)`, OpenAI function-calling, etc.) override
  `generateStructured` to constrain the model with the schema at decode
  time — strictly better than prompt-engineered "please emit JSON"
  instructions because the model can't drift.

  The `schemaID` is opaque to WorkflowKit: providers maintain their own
  registry mapping id → schema. WorkflowKit only needs to know it's
  non-empty to switch dispatch.

  Backwards-compatible: existing workflows without
  `structuredOutputSchema` and existing providers without
  `generateStructured` continue to behave identically to 0.1.3.

  Workflow output bindings now carry the structured result directly:
  steps without a schema bind as `.string(text)` (unchanged); steps
  with a schema bind as the `JSONValue` the provider returned, so
  downstream templates can address fields with `{{step.field}}`.

## [0.1.3] - 2026-05-26

### Changed

- **AgentKit no longer pollutes stdout with `print("[AGENT] ...")`
  statements.** All 32 print sites across `AgentRuntime`,
  `ProposeTool`, and `AgentApprovalSink` now go through
  `swift-log` `Logger`s under the `com.aria.agentkit.*` label
  namespace. Hosts can selectively quiet AgentKit logs via
  `LoggingSystem.bootstrap` without touching workflow / core /
  chat logs. Levels chosen by impact:
  - `.trace` — per-event noise (stepStart, assistantStart,
    toolExecutionStart, stepEnd)
  - `.debug` — within-run state (tool calls, finish reasons,
    decoded payloads)
  - `.info` — lifecycle (runStarted, resumeStreaming,
    awaitingApproval park, finished, cancelled, orphan sweep)
  - `.warning` — recovery + double-boot
  - `.error` — parse failures, hard tool errors

### Docs

- **New `docs/agentkit.md`** — comprehensive AgentKit explainer:
  recipes-vs-goals mental model, runtime stack diagram, public
  type catalog (`AgentDefinition`, stores, compiler, runtime,
  `ProposeTool`/`AgentApprovalSink`, catalog), host injection
  contract (`AgentProviderFactory` + `AgentExtraToolsProvider`),
  quick-start, settled-vs-evolving status section that flags
  the known checkpoint-restoration limitation.
- **README rebuilt** with a two-axis stack diagram showing
  `AgentKit` + `WorkflowKit` as peer runtimes above the core
  six layers, with the host app at the top and platform
  bindings (`AriaApple`/`MLX`/`Voice*`) at the bottom. Package
  layout now lists every target (was missing `AriaToolsJS`,
  `AriaVoice`, `AriaMLX`, `AriaVoiceKokoro`, `AgentKit`,
  `AriaCLI`). Reading order on the docs index extended to
  include the consumer-facing runtimes + the orthogonal feature
  docs.
- **Architecture doc** package-layout tree updated to match the
  actual repo (was stale, omitting half the targets). Target
  dependencies table now shows all eleven targets with their
  platform requirements and trait gating.
- **Glossary** got ~20 new AgentKit entries — every public
  AgentKit type now has a one-paragraph definition with the
  same voice the existing entries use.

## [0.1.2] - 2026-05-26

### Fixed

- `AriaInfo.version` was stale at `"0.0.1-alpha.9"` for the
  entire 0.0.x → 0.1.x line. Consumer apps (Avyra's
  Settings → "Powered by Aria SDK" badge, AriaCLI's
  `--version`, etc.) read this string at runtime, so the badge
  was misreporting which SDK they were actually shipping
  against. Bumped to `"0.1.2"`; future releases must keep
  this in lockstep with the tag.

## [0.1.1] - 2026-05-26

### Fixed

- **Notification `fireAt` no longer fires at the wrong wall-clock
  time when an agent schedules it.** Small on-device LLMs were
  observed emitting `fireAt` strings ending in `Z` (UTC) even
  when the system prompt clearly stated the user's local
  timezone, which shifted the scheduled fire time by the UTC
  offset (e.g. `18:00Z` fires at 11am local in
  `America/Los_Angeles`). Three layers landed:
  - `NotificationsCapability.parseFireAt(_:)` is now permissive:
    accepts the existing ISO-8601-with-timezone form, ISO-8601
    with fractional seconds, AND naïve datetimes
    (`2026-05-26T18:00:00`) which it resolves in `TimeZone.current`.
    The naïve shape is the safest contract for a model — no
    timezone for it to get wrong.
  - `AgentCompiler.currentDateAnchor()` (the block prepended to
    every system prompt) now teaches the model two safe shapes
    with concrete examples ("one hour from now is exactly
    `<naive local datetime>`") and explicitly bans `Z`.
  - Notification tool `argHint`s in `CapabilityCatalog` now
    spell out the naïve-local format and recommend `scheduleIn`
    with `secondsFromNow` whenever the user said "in N minutes"
    rather than naming a clock time.
- Regression test `scheduleAcceptsNaiveDatetimeAsLocalTime`
  in `NotificationsCapabilityTests` locks the behaviour in.

## [0.1.0] - 2026-05-26

### Added

- **`AgentKit` target** — reusable agents layer alongside
  `WorkflowKit`. Codable `AgentDefinition` (system prompt,
  model routing, tool allowlists, approval policy, triggers,
  suggested actions), JSON-file `AgentStore` / `AgentRunStore`,
  capability→tool bridging, `ProposeTool` + `AgentApprovalSink`
  for human-in-the-loop side-effecting actions, checkpoint
  middleware, in-loop validator with retry cap, and a
  generalized `AgentCompiler` / `AgentRuntime` taking two
  injected closures (`AgentExtraToolsProvider` for the host's
  MCP / workflow / plugin / skill-load tools and
  `AgentProviderFactory` for LLM routing).
  `AgentCompiler.currentDateAnchor()` injects the current date
  into every system prompt so models can't invent dates.
  `AgentCatalog` + `AgentPersona` provide the catalogue
  grouping persona buckets (For Your Day / Research /
  Communication / etc.) hosts surface in their UI.
  Apple-only; each consumer (avyra, niora) injects its own
  provider routing and extra tool sources so the runtime
  stays app-agnostic.
- **SPM traits** (SE-0480) gate the two heaviest dependency
  graphs. `MLX` enables the `AriaMLX` target (pulls in
  `mlx-swift-lm`); `VoiceKokoro` enables the `AriaVoiceKokoro`
  target (pulls in `kokoro-ios`). Both are off by default.
  See [`docs/traits.md`](docs/traits.md).
- `WorkflowKit/Engine/Skills/` now hosts the reusable
  `SkillProvider`, `SkillPromptBuilder`, and `SkillResolver`
  surface. Apps can drop these in instead of re-implementing
  the Anthropic-style `SKILL.md` loader / per-thread overrides
  store from scratch. `SkillOverridesStore` lives in
  `WorkflowKit/Storage/`.
- `CapabilityBroker.firstPartyCallerPrefix` is now configurable
  (default `"sdk.builtin."`). Lets host apps brand their
  built-in workflows under their own prefix (Avyra uses
  `"avyra.builtin."`) while still bypassing the consent prompt
  for first-party callers. Test fixtures default to
  `"sdk.builtin."`.
- **MCP tool results now surface every content block**, not just
  text. `MCPClient.callToolDetailed(name:arguments:)` returns an
  `MCPCallResult` carrying the full `[MCPContent]` (text, image,
  audio, embedded resource, resource link) plus the server's
  `isError` flag. `result.firstHTMLResource` pulls out a `ui://…`
  HTML card a tool emits to be rendered after the call —
  previously every non-text block was dropped on the floor. The
  legacy `callTool(...) -> String` is unchanged.
- Official **`modelcontextprotocol/swift-sdk`** (`MCP`) is now a
  `WorkflowKit` dependency, backing `MCPClient`. It adds only
  swift-system + the small `eventsource` package on top of the
  existing dependency graph.

### Changed

- **MLX + Kokoro voice are now targets in the root `Package.swift`**,
  not standalone sibling packages. Both targets compile to empty
  when their respective trait is off, so consumers who only want
  the FoundationModels path via `AriaApple` pay only the
  resolution-time cost — not the compile / link cost — of the MLX
  C++ backend or the Kokoro model bundle.
- **Platform floor bumped to iOS 18 / macOS 15** (was iOS 17 /
  macOS 14). Driven by the `kokoro-ios` fork's strict floor;
  SPM enforces the strictest target-required floor at the
  package level so this applies to every consumer regardless of
  trait selection.
- JS plugin file extension renamed `.avyra-tool` -> `.aria-tool`.
  The JS global injected into each tool's sandboxed `JSContext`
  is now `Aria.*` (was `Avyra.*`). Pre-release only; no on-disk
  migration shipped to users.
- **`MCPClient` is rebuilt on the official MCP SDK's
  `HTTPClientTransport`** instead of a hand-rolled JSON-only
  client. It parses both SSE and JSON responses, manages the
  session, drains `tools/list` pagination, and maps the full
  content-block set — so it works against arbitrary third-party
  servers, not just ones we configure ourselves. `MCPClient.init`
  drops its now-unused `session:` parameter.

### Fixed

- **MCP calls against SSE servers no longer fail to parse.** The
  MCP SDKs default to `text/event-stream` responses; the old
  hand-rolled client only understood JSON and threw "the data
  couldn't be read because it isn't in the correct format"
  against any server we hadn't configured for JSON. The
  SDK-backed transport parses both framings.
- **Templated `serverURL` / `toolName` in an MCP workflow step
  are now interpolated before use.** `executeMCPTool` rendered
  `argsTemplate` but used `step.serverURL` / `step.toolName` raw,
  so a step authored as `serverURL: "{{input.serverURL}}"` hit
  `URL(string:)` with the literal template and failed even when
  the run sheet supplied a valid URL. Both are rendered against
  the run's bindings now, and the `invalidServerURL` error
  reports the resolved value rather than the raw template.

### Removed

- `aria/Apps/AvyraApp/` and `aria/marketing/` moved to the
  separate Avyra repo at <https://github.com/3theories/avyra>.
  Avyra now consumes Aria as a remote SPM dependency.

### Migration

- **iOS 17 / macOS 14 consumers** are no longer supported. If
  you can't bump your deployment target, fork aria and rip the
  `AriaVoiceKokoro` target out — the rest of the package builds
  fine on the old floor.
- **Subpackage refs** are gone. If your `Package.swift`
  previously referenced `aria/MLX/` or `aria/Voice/` as separate
  packages, swap them for one aria package with the matching
  trait enabled:

  ```diff
  - .package(path: "../aria/MLX"),
  - .package(path: "../aria/Voice"),
  + .package(
  +     url: "https://github.com/prasadpamidi/aria.git",
  +     from: "0.1.0",
  +     traits: ["MLX", "VoiceKokoro"]
  + ),
  ```

  Target dependencies stay the same (`AriaMLX`, `AriaVoiceKokoro`)
  — they're now products of the unified package.
- **CapabilityBroker callers** that relied on the implicit
  `"sdk.builtin."` first-party prefix continue to work without
  changes. Apps that want their own prefix should pass it
  explicitly:

  ```swift
  let broker = CapabilityBroker(firstPartyCallerPrefix: "myapp.builtin.")
  ```

- **JS plugin files** with the `.avyra-tool` extension must be
  re-saved as `.aria-tool`. The bundle JSON shape is unchanged.
  Plugin source that references `Avyra.http`, `Avyra.json`, etc.
  must be updated to `Aria.http` / `Aria.json` / etc. The
  capability set (`http`, `json`, `clipboard`, `share`, `notify`,
  `storage`) is unchanged.
