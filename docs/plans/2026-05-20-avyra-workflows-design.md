# Avyra Workflows — P0 Design

**Status:** Validated 2026-05-20 via brainstorming with @prasadpamidi.
**Implementation:** Tracked in a sibling `…-plan.md` produced by `superpowers:writing-plans`.

---

## North star

Avyra becomes a personal automation runtime on top of Aria. End users assemble workflows from templates; tinkerers author both visual workflows and JS plugins in-app. Workflows trigger from anywhere in iOS (Shortcuts, Siri, widgets, URL schemes).

**Headline demo:** *"Hey Siri, daily brief"* → a multi-step agent that pulls Calendar + HealthKit + Location, calls a weather JS plugin (using a Keychain-stored API key), narrates a 30-second summary aloud.

## Audience

End users **and** power-user tinkerers. Layered surface:
- **Default** — template gallery + linear recipe editor. Hidden complexity.
- **Power** — graph toggle + JS code editor + capability management. Discoverable but not in your face.
- **Developer mode** — traces, metrics, raw session JSON.

## P0 scope (~8 weeks)

In-scope:
- Workflow data model + compile-to-`Aria.StateGraph` engine
- Linear recipe editor with graph-toggle escape
- In-app JS code editor (Runestone)
- Five native capabilities: **Secrets**, **Calendar/Reminders**, **HealthKit**, **Location**, **Files (read-only)**
- JS std lib: `storage`, `secrets`, `crypto`, `url`, `time`, `prompt.user`, `log`
- Daily Brief built-in template + Weather JS plugin it depends on
- AppIntents bridge so Daily Brief is Siri/Shortcuts callable

Deferred:
- Control Center widgets, lock-screen widgets (P1)
- Plugin community sharing / marketplace (P2)
- Background-scheduled execution (use Shortcuts.app Automations as the iOS-permitted path)
- Photos+Vision, HomeKit, Music caps
- Library templates beyond Daily Brief

## Architecture

Three new modules between the Avyra UI and the existing Aria runtime:

```
Avyra UI (SwiftUI)
       │
WorkflowKit       — Workflow model, GRDB persistence, StateGraph compiler,
                    TriggerDispatcher, CapabilityBroker
       │
Aria runtime      — Agent / StateGraph / AriaToolsJS (unchanged)
       │
Native capabilities — Secrets, Health, Calendar/Reminders, Location, Files
```

### Data model

```swift
struct Workflow: Codable, Identifiable {
    let id: UUID
    var name: String
    var summary: String
    var inputSchema: InputSchema      // typed AppIntent parameter
    var outputSchema: OutputSchema
    var nodes: [WorkflowNode]
    var edges: [WorkflowEdge]         // omit for linear workflows
    var triggers: Set<Trigger>        // .manual / .shortcuts / .urlScheme
    var modelHint: ModelFamily?       // soft model preference
    var toolPolicy: ToolPolicy
    var memoryPolicy: MemoryPolicy
}

enum WorkflowNode: Codable {
    case llm(LLMStep)                  // prompt template + structured output
    case capability(CapabilityStep)    // native cap or JS plugin call
    case transform(TransformStep)      // small JS expression
    case branch(BranchStep)
    case parallel([UUID])              // children run concurrently
    case output(OutputStep)
}
```

### Compile pipeline

At run time, `WorkflowCompiler.compile(workflow)` walks the nodes and produces an `Aria.StateGraph<WorkflowState>`. Edges become transitions. The agent runs through `StateGraphRunner` — tracing, checkpointing, parallelism, recording are inherited from Aria.

The editor never speaks StateGraph directly; it edits `Workflow` JSON, persists to GRDB, compiles only at run time. Sharing is JSON export.

## Capabilities matrix

All caps flow through one `CapabilityBroker` that checks user-granted scopes before each call.

### Native caps (P0)

| ID | Framework | Surface |
|---|---|---|
| `secrets` | Keychain + LAContext | `get(key)`, `set(key, value)`, `list()`; per-key biometric flag |
| `health` | HealthKit | `recentSteps(days)`, `lastSleep()`, `lastWorkout()`, `water(today)` (read-only) |
| `calendar` | EventKit | `eventsToday()`, `eventsBetween(start, end)`, `upcomingReminders(n)` |
| `location` | CoreLocation | `current()` (one-shot, low-accuracy default), `geocode(address)` |
| `files` | UIDocumentPicker | `readText(url)`, `readPDF(url)` (user-picked only, no enumeration) |

### JS std lib

| Module | Methods |
|---|---|
| `storage` | `get(k)`, `set(k, v)`, `delete(k)` — sandboxed per plugin id |
| `secrets` | Bridge to native cap |
| `crypto` | `hash(alg, data)`, `hmac(alg, key, data)`, `base64.encode/decode` |
| `url` | `parse(s)`, `build(parts)`, `encode(s)`, `decode(s)` |
| `time` | `now()`, `format(date, fmt)`, `parse(s)` |
| `prompt` | `user(question)` — attended runs only |
| `log` | `info/debug/warn(msg)` — surfaces in test panel + traces |

### Consent model

**Hybrid:** install-time approval + per-key biometric toggle.

Manifest's `capabilities: [...]` and `keys: [...]` produce one combined consent sheet at install. After install, granted caps are silent — works in unattended Siri/widget runs. User can flip any individual key to **Require Face ID** in Settings; those reads invoke `LAContext.evaluatePolicy` and fail gracefully (return nil) in unattended runs.

```
Weather Plugin wants to:
  ✓ Make HTTP requests
  ✓ Read & write storage
  ✓ Read 1 secret: OPENWEATHER_API_KEY

[ Install ]  [ Cancel ]
```

## Editor UX

**Linear recipe by default.** Vertical list of step cards. Each card is one `WorkflowNode`. Drag to reorder. Tap to edit.

**Graph toggle.** A toolbar button flips to a SwiftUI Canvas with draggable nodes + edges. Same data model. Used for parallel/branch cases.

**JS code editor.** Runestone-backed surface for authoring `.avyra-tool` plugins in-app. Manifest-aware autocomplete (`aria.` reveals declared capabilities). Dry-run button executes against a synthetic input in a sandboxed `JSContext`; `log.*` output and final return value stream into a side panel.

**Test panel.** Live workflow run against synthetic input. Every node's input/output diff, traces, token usage rendered inline.

## Triggers

**P0 — AppIntents bridge.** Each user workflow with `Trigger.shortcuts` in its set registers a dynamic `AppIntent` at app launch via the AppIntents framework's `DynamicOptionsProvider`. This single registration covers Shortcuts.app, Siri, Spotlight, Watch, Shortcuts on iPadOS.

**P0 — URL scheme.** `avyra://run?workflow=<id>&input=<urlencoded>` for x-callback chains.

**P1** — Control widgets (iOS 18+), home/lock-screen widgets.

**Background schedule** = Shortcuts.app Automations firing the Avyra AppIntent. We don't own a scheduler.

## Demos / templates

P0 ships exactly one built-in template, **Daily Brief**:
- Step 1: `capability.calendar.eventsToday()`
- Step 2: `capability.health.lastSleep()`
- Step 3: `capability.location.current()` → reverse geocode → city
- Step 4: `capability.plugin("weather").call({city: $step3.city})`
- Step 5: `llm` — prompt = "Narrate a 30-second morning brief for {{user_name}} using …" — structured output `{ headline, details, mood }`
- Step 6: `output` — `{ spoken_text: $step5.headline + " " + $step5.details }`

Voice mode reads the `spoken_text` via Kokoro (or system voice). Siri invocation reads it through SiriKit's TTS layer.

## Risks called out at design time

- **iOS background limits** — scheduling lives in Shortcuts.app, not in Avyra.
- **AppIntent typed parameters** — Siri-friendly intents need concrete `AppEntity` types. P0 supports `String` and `Date` parameters; richer types in P1.
- **FoundationModels reliability** — multi-step workflows need retry policy at the StateGraph layer.
- **JSContext lifetime** — long-running workflows that call JS many times need explicit context reuse.
- **Plugin install supply chain** — sharing flow needs signing or manifest review before P2 community marketplace.
- **In-app code editor** — Runestone is a new SPM dep (~1MB compiled). BSD license, no entitlement implications.

## What's explicitly out of scope (not deferred — out)

- Cloud sync of workflows / plugins (workflows are device-local for P0).
- Workflow versioning UI (snapshots live in GRDB but no diff/restore UI).
- Plugin discoverability beyond `.avyra-tool` import + built-in Daily Brief.
- Multi-user / shared workflows.

## Non-automatable bits the human owns

1. Apple Developer Portal: enable HealthKit, Calendar, Location capabilities on the App ID when those slices land.
2. End-to-end Siri verification on a real device after a signed build.
3. App Store metadata changes if/when shipping (out of P0 scope but worth noting).
