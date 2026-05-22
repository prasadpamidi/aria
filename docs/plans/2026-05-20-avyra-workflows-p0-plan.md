# Avyra Workflows P0 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ship the Avyra Workflows P0 surface: a workflow data model + compile-to-`Aria.StateGraph` engine, five native capabilities (Secrets, Calendar/Reminders, HealthKit, Location, Files), an expanded JS std lib, a linear-recipe editor with graph toggle, an in-app Runestone-based JS editor, an AppIntents bridge, and one Daily Brief built-in template + Weather JS plugin.

**Architecture:** New `WorkflowKit` SPM target sits between Avyra UI and the existing Aria runtime. Workflows are Codable JSON persisted via GRDB; at run time `WorkflowCompiler` lowers them to `Aria.StateGraph<WorkflowState>`. A `CapabilityBroker` mediates every native + JS capability call against user-granted scopes. AppIntents are registered dynamically per "exposed" workflow.

**Tech Stack:** Swift 6 / SwiftUI / Aria + AriaApple + AriaToolsJS / GRDB / EventKit / HealthKit / CoreLocation / PDFKit / LocalAuthentication / Runestone (new SPM dep) / AppIntents.

**Source design:** `docs/plans/2026-05-20-avyra-workflows-design.md` — referenced throughout; do not duplicate decisions captured there.

---

## Delivery contract

- Worktree: `/Users/prasadpamidi/aria/.worktrees/avyra-workflows-p0` on branch `feat/avyra-workflows-p0`.
- Every slice ends with `bundle exec fastlane app_local_build` green **and** new tests passing under `bundle exec fastlane package_tests`.
- Commit after every passing test; commit after every passing slice exit.
- Non-automatable user gates (called out per slice): Apple Dev Portal capability toggles, end-to-end Siri verification on a device, Runestone SPM dep approval.

## Slice index

| # | Slice | Why it's a slice (exit criterion) |
|---|---|---|
| 0 | Bootstrap: WorkflowKit target + entitlements scaffolding | Empty WorkflowKit target builds and links into Avyra. |
| 1 | Workflow data model + JSON round-trip | `Workflow` Codable model with 100% serialization test coverage. |
| 2 | GRDB persistence | Workflows persist + load; migration applies; tests pass. |
| 3 | CapabilityBroker foundation | Broker mediates fake caps; consent grants persist; tests pass. |
| 4 | SecretsCapability (Keychain + LAContext) | Read/write/list scoped to plugin id; biometric toggle works in unit harness. |
| 5 | WorkflowCompiler → StateGraph | Linear workflow with mock LLM + mock capability runs end-to-end in a test. |
| 6 | CalendarRemindersCapability | EventKit reads work; mocked tests pass; usage strings in Info.plist. |
| 7 | HealthCapability | HealthKit reads work; mocked tests pass; usage string in Info.plist. |
| 8 | LocationCapability | One-shot location works; usage string in Info.plist; tests pass. |
| 9 | FilesCapability | UIDocumentPicker text + PDF read works; tests pass. |
| 10 | JS std lib expansion | New modules registered, accessible from JS, sandbox boundaries tested. |
| 11 | AppIntents bridge + URL scheme | One static AppIntent dispatches a workflow by id; URL scheme works. |
| 12 | Linear recipe editor (UI) | Create/edit/delete a workflow with linear step cards; UI compiles + smoke-renders. |
| 13 | Graph toggle (UI) | Same workflow renders in a node/edge canvas. |
| 14 | Runestone JS editor (UI) | Edit + dry-run a JS plugin in-app. |
| 15 | Daily Brief template + Weather plugin + integration | "Hey Siri, daily brief" plays back through Avyra on a sim, narrated. |

Detailed tasks below. Each task lists files to touch, the failing test first, the minimum implementation, and the commit shape. **Slices 0–5 are fully expanded; slices 6+ have outline-level task lists that get expanded immediately before execution.**

---

## Slice 0 — Bootstrap: WorkflowKit target + entitlements scaffolding

**Exit criterion:** Empty `WorkflowKit` target builds. Avyra app target imports `WorkflowKit` (unused symbol fine). `bundle exec fastlane app_local_build` green.

### Task 0.1 — Add WorkflowKit target to `Package.swift`

**Files:**
- Modify: `/Users/prasadpamidi/aria/Package.swift` (in the worktree)
- Create: `/Users/prasadpamidi/aria/Sources/WorkflowKit/WorkflowKit.swift`
- Create: `/Users/prasadpamidi/aria/Tests/WorkflowKitTests/WorkflowKitVersionTests.swift`

**Step 1.** Add product + target to `Package.swift`:

```swift
// products
.library(name: "WorkflowKit", targets: ["WorkflowKit"]),

// targets
.target(
    name: "WorkflowKit",
    dependencies: ["Aria", "AriaTools", "AriaToolsJS"],
    path: "Sources/WorkflowKit"
),
.testTarget(
    name: "WorkflowKitTests",
    dependencies: ["WorkflowKit", "AriaTesting"],
    path: "Tests/WorkflowKitTests"
),
```

**Step 2.** Stub source — version sentinel so tests have something to assert on:

```swift
// Sources/WorkflowKit/WorkflowKit.swift
public enum WorkflowKitInfo {
    public static let version = "0.1.0"
}
```

**Step 3.** Stub test:

```swift
// Tests/WorkflowKitTests/WorkflowKitVersionTests.swift
import Testing
@testable import WorkflowKit

@Test
func workflowKitVersionIsAvailable() {
    #expect(!WorkflowKitInfo.version.isEmpty)
}
```

**Step 4.** Run `swift test --filter WorkflowKitVersionTests`. Expect 1 pass.

**Step 5.** Commit: `feat(workflowkit): add empty WorkflowKit target scaffold`.

### Task 0.2 — Link WorkflowKit into the Avyra Xcode target

**Files:**
- Modify: `Apps/AvyraApp/Avyra.xcodeproj/project.pbxproj`

**Steps:**
1. Append a new `XCSwiftPackageProductDependency` (`AA00000000000000000000BE /* WorkflowKit */`) referencing `../..`, product `WorkflowKit`.
2. Add corresponding `PBXBuildFile` and slot it into the Avyra app target's Frameworks build phase + `packageProductDependencies` list.
3. Add `import WorkflowKit` to `Apps/AvyraApp/Avyra/App/AvyraApp.swift` (no symbol use yet — just verify link).
4. Run `bundle exec fastlane app_local_build`. Expect green.
5. Commit: `chore(avyra): link WorkflowKit into Avyra target`.

### Task 0.3 — Entitlements + usage strings scaffolding

**Files:**
- Modify: `Apps/AvyraApp/Avyra/Avyra.entitlements`
- Modify: `Apps/AvyraApp/Avyra/Info.plist`

**Entitlements:** Add empty stubs for `com.apple.developer.healthkit`, `com.apple.developer.healthkit.access`, then `keychain-access-groups` for `$(AppIdentifierPrefix)com.3theories.app.Avyra`.

**Info.plist usage strings (P0 set, all required for capabilities to function):**

```xml
<key>NSHealthShareUsageDescription</key>
<string>Avyra reads health metrics (steps, sleep, workouts) only to power workflows you run.</string>
<key>NSCalendarsFullAccessUsageDescription</key>
<string>Avyra reads your calendar to summarize your day and power workflows you build.</string>
<key>NSRemindersFullAccessUsageDescription</key>
<string>Avyra reads your reminders to power workflows you build.</string>
<key>NSContactsUsageDescription</key>
<string>Avyra reads contacts only when a workflow you run requests it.</string>
<key>NSLocationWhenInUseUsageDescription</key>
<string>Avyra uses your location to enrich workflows like the Daily Brief.</string>
```

**Steps:**
1. Add entitlement entries (mark stubs commented if not yet linked to actual code).
2. Add usage strings.
3. Run `bundle exec fastlane app_local_build`. Expect green (signing automatic).
4. Commit: `chore(avyra): add usage strings + entitlement stubs for P0 capabilities`.

**🛑 Human gate after Slice 0:** Verify HealthKit / Calendar / Location capabilities are enabled on the App ID `com.3theories.app.Avyra` in Apple Developer Portal (or accept Xcode auto-prompt). I will pause and surface this before proceeding to Slice 6.

---

## Slice 1 — Workflow data model + JSON round-trip

**Exit criterion:** `Workflow` model has full Codable round-trip tests for every node variant.

### Task 1.1 — Core enum types

**Files:**
- Create: `Sources/WorkflowKit/Model/WorkflowEnums.swift`
- Create: `Tests/WorkflowKitTests/WorkflowEnumsTests.swift`

**Type list (one file, tightly scoped — DRY against future slices):**

```swift
public enum CapabilityID: String, Codable, CaseIterable, Sendable {
    case secrets, health, calendar, location, files, http
}

public enum Trigger: String, Codable, Sendable {
    case manual, shortcuts, urlScheme
}

public enum ModelFamilyHint: String, Codable, Sendable {
    case foundationModels, llama, qwen, gemma, any
}

public struct InputField: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case text, date, number, bool }
    public let id: String
    public let label: String
    public let kind: Kind
    public let optional: Bool
}

public struct InputSchema: Codable, Sendable {
    public let fields: [InputField]
}

public struct OutputField: Codable, Sendable {
    public let id: String
    public let label: String
}

public struct OutputSchema: Codable, Sendable {
    public let fields: [OutputField]
}
```

**Test:** Round-trip each via `JSONEncoder`/`JSONDecoder`; assert equality. Five `#expect` cases.

**Commit:** `feat(workflowkit): core enum + schema types with Codable tests`.

### Task 1.2 — WorkflowNode variants

**Files:**
- Create: `Sources/WorkflowKit/Model/WorkflowNode.swift`
- Create: `Tests/WorkflowKitTests/WorkflowNodeTests.swift`

**Type:**

```swift
public enum WorkflowNode: Codable, Sendable, Identifiable {
    case llm(LLMStep)
    case capability(CapabilityStep)
    case transform(TransformStep)
    case branch(BranchStep)
    case parallel(ParallelStep)
    case output(OutputStep)

    public var id: UUID { /* dispatch */ }
}

public struct LLMStep: Codable, Sendable {
    public let id: UUID
    public let promptTemplate: String          // "{{step1.headline}}…"
    public let structuredOutputSchema: String? // JSONSchema as string
    public let modelHint: ModelFamilyHint
    public let maxTokens: Int?
}

public struct CapabilityStep: Codable, Sendable {
    public let id: UUID
    public let capability: CapabilityID
    public let method: String                  // "eventsToday"
    public let argsTemplate: [String: String]  // values are templated strings
    public let outputBinding: String           // e.g. "events"
}

public struct TransformStep: Codable, Sendable {
    public let id: UUID
    public let jsExpression: String
    public let outputBinding: String
}

public struct BranchStep: Codable, Sendable {
    public let id: UUID
    public let condition: String               // JS expression returning bool
    public let trueBranch: [UUID]
    public let falseBranch: [UUID]
}

public struct ParallelStep: Codable, Sendable {
    public let id: UUID
    public let children: [UUID]
}

public struct OutputStep: Codable, Sendable {
    public let id: UUID
    public let fields: [String: String]        // outputId -> templated value
}
```

**Test:** Build one instance of every variant; round-trip via JSON; assert decoded matches encoded. Six tests.

**Commit:** `feat(workflowkit): WorkflowNode variants with Codable round-trip`.

### Task 1.3 — Top-level Workflow

**Files:**
- Create: `Sources/WorkflowKit/Model/Workflow.swift`
- Create: `Tests/WorkflowKitTests/WorkflowTests.swift`

**Type:**

```swift
public struct Workflow: Codable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var summary: String
    public var inputSchema: InputSchema
    public var outputSchema: OutputSchema
    public var nodes: [WorkflowNode]
    public var edges: [WorkflowEdge]
    public var triggers: Set<Trigger>
    public var modelHint: ModelFamilyHint
    public var toolPolicy: ToolPolicy
    public var memoryPolicy: MemoryPolicy
    public var createdAt: Date
    public var updatedAt: Date
}

public struct WorkflowEdge: Codable, Sendable {
    public let from: UUID
    public let to: UUID
}

public struct ToolPolicy: Codable, Sendable {
    public let allowedCapabilities: Set<CapabilityID>
    public let allowedPlugins: Set<String>     // plugin bundle ids
}

public struct MemoryPolicy: Codable, Sendable {
    public enum Mode: String, Codable, Sendable { case isolated, shared }
    public let mode: Mode
    public let threadId: String
}
```

**Test:** Build a 3-node linear workflow; round-trip; assert. One test.

**Commit:** `feat(workflowkit): Workflow top-level type with round-trip test`.

### Task 1.4 — JSON file import/export helpers

**Files:**
- Create: `Sources/WorkflowKit/Model/WorkflowCodec.swift`
- Create: `Tests/WorkflowKitTests/WorkflowCodecTests.swift`

**Type:**

```swift
public enum WorkflowCodec {
    public static func encode(_ workflow: Workflow) throws -> Data
    public static func decode(_ data: Data) throws -> Workflow
    public static func encode(_ workflow: Workflow, to url: URL) throws
    public static func decode(from url: URL) throws -> Workflow
}
```

**Test:** Write to a temp file, read back, assert equal. Two tests.

**Commit:** `feat(workflowkit): WorkflowCodec encode/decode helpers`.

**Slice 1 exit:** `swift test --filter WorkflowKitTests` → ~15 passing tests. `bundle exec fastlane app_local_build` green.

---

## Slice 2 — GRDB persistence

**Exit criterion:** A `WorkflowStore` saves, loads, lists, and deletes workflows via GRDB. Migration applies. Tests cover the four operations.

### Tasks (compressed)

- **2.1** Create `Sources/WorkflowKit/Storage/WorkflowRecord.swift`: GRDB `FetchableRecord` + `MutablePersistableRecord` shape (`id`, `json` blob, `name`, `updatedAt`).
- **2.2** Create `Sources/WorkflowKit/Storage/WorkflowStore.swift`: actor wrapping `DatabasePool`, ops `save / load(id:) / list() / delete(id:)`.
- **2.3** Create `Sources/WorkflowKit/Storage/WorkflowMigrator.swift`: registers `v1_workflows` migration.
- **2.4** Tests using in-memory SQLite — round-trip + listing ordering + delete.
- **2.5** Hook `WorkflowStore` initialization into `AvyraApp.swift` (share the existing `GRDBStorage`'s pool — add a new migrator entry there).

Each task ≤ 5 minutes, ends with a passing test, commits independently.

**Exit:** `swift test --filter WorkflowStore` green; app builds.

---

## Slice 3 — CapabilityBroker foundation

**Exit criterion:** `CapabilityBroker.call(plugin:cap:method:args:)` succeeds when scope is granted, throws `.notGranted` when not.

### Tasks (compressed)

- **3.1** Types: `Sources/WorkflowKit/Capabilities/Capability.swift` — `Capability` protocol, `CapabilityCallContext`, `CapabilityError` enum.
- **3.2** `CapabilityScope` Codable type — `(pluginId, cap, methods?)`. Persisted via simple JSON blob in GRDB.
- **3.3** `CapabilityBroker` actor that dispatches to registered `Capability` impls; verifies scope; logs to recorder.
- **3.4** `FakeCapability` test double + scope grant/revoke tests.
- **3.5** `ConsentSheetModel` (UI-agnostic) that produces an install-time consent payload from a plugin manifest.
- **3.6** SwiftUI `CapabilityConsentSheet` view rendered from the model — basic Cancel / Install buttons; no styling polish yet.

**Exit:** `swift test --filter CapabilityBroker` green; app builds; new sheet visible behind a test trigger in `DemosScreen`.

---

## Slice 4 — SecretsCapability (Keychain + LAContext)

**Exit criterion:** SecretsCapability reads/writes per-plugin-scoped keychain items; biometric toggle gates reads when on; tests pass.

### Tasks (compressed)

- **4.1** `Sources/WorkflowKit/Capabilities/SecretsCapability.swift` — wraps `Security` framework. Keychain key prefix = `\(pluginId)::\(keyName)`. Access control: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- **4.2** Biometric flag stored as a separate keychain item (`__bio.\(pluginId)::\(keyName)`); when set, reads use `kSecUseAuthenticationContext` with `LAContext`.
- **4.3** Unit tests using a `MockKeychain` protocol shim — verify partition isolation + biometric path.
- **4.4** `SecretsVaultScreen` SwiftUI surface — list keys for a plugin, rename / delete, biometric toggle.
- **4.5** Wire into `ToolsSettingsScreen` (per-plugin "Stored keys" navigation link).

**Exit:** `swift test --filter SecretsCapability` green; app builds; vault accessible from plugin detail screen.

---

## Slice 5 — WorkflowCompiler → StateGraph

**Exit criterion:** A 3-node linear workflow (capability → llm → output) compiles to an `Aria.StateGraph` and runs end-to-end against mock provider + mock capability in a test.

### Tasks (compressed)

- **5.1** `Sources/WorkflowKit/Engine/WorkflowState.swift` — observable state struct: `bindings: [String: JSONValue]`, `currentNode: UUID?`, `error: Error?`.
- **5.2** `Sources/WorkflowKit/Engine/TemplateInterpolator.swift` — `{{stepId.field}}` → value lookup against state bindings. Tests for nested paths + missing-key behavior.
- **5.3** `Sources/WorkflowKit/Engine/WorkflowCompiler.swift` — `func compile(_ workflow: Workflow, broker: CapabilityBroker, agentFactory: AgentFactory) -> StateGraph<WorkflowState>`. Maps each node to a `StateGraph` node:
  - `llm` → build a one-shot Agent run + structured output capture.
  - `capability` → call broker, bind output.
  - `transform` → execute JS expression in scratch `JSContext`.
  - `branch` → state graph conditional transition.
  - `parallel` → state graph parallel step.
  - `output` → terminal node populating return dict.
- **5.4** `Sources/WorkflowKit/Engine/WorkflowRunner.swift` — public entry: `run(workflow:input:) async throws -> [String: JSONValue]`.
- **5.5** Integration test: mock provider, mock capability, assert final state and bindings.

**Exit:** `swift test --filter WorkflowEngine` green; app builds.

---

## Slice 6 — CalendarRemindersCapability

**Compressed task list:**
- `Sources/WorkflowKit/Capabilities/CalendarRemindersCapability.swift` (EventKit).
- Method routing: `eventsToday`, `eventsBetween`, `upcomingReminders(n)`.
- iOS 17+ `EKEventStore.requestFullAccessToEvents` / `requestFullAccessToReminders` flow.
- Tests using `EKEventStore` injection / mock.
- Wire into broker registry.

**Exit:** EventKit reads in a test fixture work; app builds; usage strings already in place from Slice 0.

**🛑 Possible human gate:** if the simulator hasn't pre-authorized calendar in this session, a runtime grant will need to be tapped manually for any UI smoke test. Unit tests don't need it.

---

## Slice 7 — HealthCapability

- `Sources/WorkflowKit/Capabilities/HealthCapability.swift` (HealthKit).
- Method routing: `recentSteps(days)`, `lastSleep()`, `lastWorkout()`, `water(today)`.
- Authorization request flow on first call.
- Tests using `HKHealthStore` injection / mock.
- Wire into broker.

**🛑 Human gate:** real HealthKit data only appears on a device, not a sim. Sim runs return placeholder zeros; that's expected.

---

## Slice 8 — LocationCapability

- `Sources/WorkflowKit/Capabilities/LocationCapability.swift` (CoreLocation).
- One-shot `requestLocation()` with low accuracy default; `geocode(address)` via `CLGeocoder`.
- Tests with `CLLocationManager` test double.
- Wire into broker.

---

## Slice 9 — FilesCapability

- `Sources/WorkflowKit/Capabilities/FilesCapability.swift`.
- Surfaces `UIDocumentPickerViewController` from SwiftUI via `UIViewControllerRepresentable`.
- `readText(url)` via `String(contentsOf:)`, `readPDF(url)` via `PDFKit`.
- No filesystem enumeration — only user-picked URLs.
- Tests via direct URL injection.

---

## Slice 10 — JS std lib expansion

Each module is a function family registered in `JSToolRuntime` (existing). Source files live under `Sources/AriaToolsJS/StdLib/`.

- **10.1** `storage` — `JSToolStorageModule.swift`. Sandboxed per `pluginId` via GRDB blob table.
- **10.2** `secrets` — bridge to native `SecretsCapability`; injection point at runtime.
- **10.3** `crypto` — wrap `CryptoKit`.
- **10.4** `url` — `Foundation.URLComponents` wrapper.
- **10.5** `time` — `Foundation.DateFormatter` wrapper.
- **10.6** `prompt.user` — `NotificationCenter`-bridged to the active workflow UI; throws when no UI is attached (unattended run).
- **10.7** `log` — captures into the active `SessionRecorder` + the test panel.

Each module ships with `Tests/AriaToolsJSTests/StdLib/*Tests.swift` running through a hosted `JSContext`.

**Exit:** `swift test --filter AriaToolsJS` green.

---

## Slice 11 — AppIntents bridge + URL scheme

- **11.1** `Apps/AvyraApp/Avyra/Intents/RunWorkflowIntent.swift` — `AppIntent` with `workflowId: String` + `input: String?`. `perform()` resolves the workflow from store and runs it through `WorkflowRunner`. Returns `IntentResult & ReturnsValue<String>`.
- **11.2** `WorkflowAppIntentRegistrar` — at app launch, enumerates workflows with `Trigger.shortcuts` and donates via `IntentDonationManager`.
- **11.3** `Apps/AvyraApp/Avyra/Intents/AvyraShortcutsProvider.swift` — `AppShortcutsProvider`, declares the static Daily Brief phrase.
- **11.4** URL scheme handler `avyra://run?workflow=<id>&input=<urlencoded>` in `App.onOpenURL`.
- **11.5** Integration tests via direct intent invocation.

---

## Slice 12 — Linear recipe editor (UI)

- **12.1** `WorkflowListScreen.swift` — list of saved workflows + "+" button → template picker.
- **12.2** `WorkflowEditorScreen.swift` — top-level container hosting Recipe vs Graph toggle.
- **12.3** `RecipeCanvas.swift` — vertical `List` of step cards with drag-to-reorder.
- **12.4** `StepCardView.swift` — discloses to `StepEditorSheet` for the picked node type.
- **12.5** `StepPickerSheet.swift` — segmented list of node types.
- **12.6** `VariablePickerField.swift` — text field with `{{…}}` autocomplete pulling from prior steps' output bindings.
- **12.7** Mount under Settings → Workflows.

Tests: build editor with seed workflow, assert renders without crash via `ViewInspector`-style snapshots (or simple view-model unit tests where possible — SwiftUI snapshot infra in repo is light).

---

## Slice 13 — Graph toggle (UI)

- **13.1** `GraphCanvas.swift` — `Canvas` rendering nodes + edges from the same `Workflow`.
- **13.2** Pan/zoom via `MagnificationGesture` + `DragGesture` composition.
- **13.3** Tap a node → opens same `StepEditorSheet` as recipe view.
- **13.4** Layout: simple layered (longest-path layering) — compute once on workflow load; user can drag to override; positions persisted in `WorkflowEdge.metadata` (extend model).

---

## Slice 14 — Runestone JS editor (UI)

- **14.1** Add Runestone SPM dep to `Package.swift` (root) + Avyra Xcode project.
- **14.2** `JSEditorScreen.swift` — wraps Runestone via `UIViewRepresentable`, Tree-sitter JS grammar bundled.
- **14.3** Autocomplete provider that introspects `aria.*` from the active capability manifest.
- **14.4** Dry-run panel — runs the JS via `JSToolRuntime` against a user-entered JSON input, streams `log.*` + return value into a side pane.
- **14.5** Save versions to GRDB (`PluginVersion` table) — latest is active, prior list shown in a drawer.
- **14.6** Wire into `ToolsSettingsScreen` plugin detail (developer-mode-only entry).

**🛑 Human gate at start of 14:** Confirm Runestone is OK to add as a dep. If not, fall back to a simpler editor (`UITextView` with very basic syntax via `NSAttributedString`).

---

## Slice 15 — Daily Brief template + Weather plugin + integration

- **15.1** Bundle Daily Brief workflow JSON at `Apps/AvyraApp/Avyra/Resources/Workflows/daily-brief.json`. Compose against final capability surface.
- **15.2** Bundle Weather plugin `.avyra-tool` at `Apps/AvyraApp/Avyra/Resources/Plugins/weather/`. Uses `secrets.get('OPENWEATHER_API_KEY')` + `fetch`.
- **15.3** First-run seeding: if no workflows exist, install Daily Brief on app launch.
- **15.4** Voice output integration — `OutputStep` with field id `spoken_text` triggers Kokoro/system voice via existing `VoiceController`.
- **15.5** End-to-end smoke: run Daily Brief manually, then via the in-app intent test surface.
- **15.6** Final `bundle exec fastlane app_tests` + `package_tests` green.

**🛑 Final human gate:** "Hey Siri, daily brief" verification on a device. I cannot do this from here.

---

## Risks tracked during execution

(Plain copy of the design doc's risk list — referenced when a slice hits any.)

- iOS background limits — Shortcuts.app Automation only.
- AppIntent typed parameters limited to `String` / `Date` in P0.
- FoundationModels reliability — Slice 5 adds retry policy at StateGraph layer.
- JSContext lifetime — Slice 10 explicitly reuses context per workflow run.
- Plugin install supply chain — `.avyra-tool` import only in P0.
- Runestone dep — Slice 14 gates on user OK.

---

## What happens if I hit a fork I can't unblock

I will halt and surface the fork explicitly. Examples:
- Apple Dev Portal capability missing → Slice 6/7/8 fails to sign → halt.
- Runestone license / dep refused → fall back path documented in 14.6.
- Daily Brief Siri verification fails → halt (it's a human-only verification).

Everything else gets resolved in-session.
