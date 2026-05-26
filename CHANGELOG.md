# Changelog

All notable changes to Aria are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and Aria adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
