# JS Plugin Tools

`AriaToolsJS` is Aria's sandboxed JavaScript plugin runtime. It
lets a host app ship — and users author — tools the model can call
without recompiling the app. Each plugin is a single
`.aria-tool` JSON file with a manifest plus an
`async function call(input)` JS body. The runtime loads each
plugin into its own `JSContext`, wires a curated host-bridge object
based on the manifest's declared capabilities, and vends the
plugins as `[AnyTool]` ready to drop into `AgentConfig.tools`.

`AriaToolsJS` is Apple-only — it requires `JavaScriptCore`. The
target's sources are guarded with `#if canImport(JavaScriptCore)`
so the package still builds on Linux; the target just compiles
empty there.

## Bundle format

`JSToolBundle` is the on-disk shape. One JSON file, all the
metadata up front, the JS source as the `main` string field. Picked
single-file over a folder because AirDrop / Messages / Files all
handle one file cleanly; folder distribution would have meant
zipping for sharing.

| Field | Type | Notes |
| --- | --- | --- |
| `manifestVersion` | Int | Bumped when the format is non-backwards-compatible. The loader rejects bundles with `manifestVersion > currentManifestVersion`. |
| `id` | String | Stable reverse-DNS identifier (`so.example.weather`). Used as the storage namespace key and collision-detection key. |
| `name` | String | Snake-case tool name surfaced to the model via `ToolDefinition.name`. |
| `displayName` | String? | Human-readable name for install UI. Falls back to `name`. |
| `description` | String | Shown to the model AND the user. Should explain *when* the tool is useful, not just what it does. |
| `version` | String | Free-form; semver recommended. |
| `author` | String? | Display only. |
| `capabilities` | `[JSToolCapability]` | Declared up front. Anything not listed is unreachable from the JS body. |
| `inputSchema` | `JSONSchema` | Forwarded into `ToolDefinition.inputSchema` so the model gets a typed signature. |
| `main` | String | JS source. Must define `async function call(input)` at top level. |

### Example: weather lookup

```json
{
  "manifestVersion": 1,
  "id": "so.example.weather",
  "name": "weather",
  "displayName": "Weather",
  "description": "Look up the current weather for a city by name.",
  "version": "1.0.0",
  "author": "Jane Doe",
  "capabilities": ["http", "json"],
  "inputSchema": {
    "type": "object",
    "properties": {
      "city": {
        "type": "string",
        "description": "City name, optionally followed by country code."
      }
    },
    "required": ["city"]
  },
  "main": "async function call(input) {\n  const r = await Aria.http.get(`https://wttr.in/${encodeURIComponent(input.city)}?format=j1`);\n  if (r.status !== 200) {\n    throw new Error(`weather lookup failed: ${r.status}`);\n  }\n  const data = Aria.json.parse(r.body);\n  const current = data.current_condition[0];\n  return {\n    city: input.city,\n    tempC: parseFloat(current.temp_C),\n    description: current.weatherDesc[0].value,\n    humidity: parseFloat(current.humidity)\n  };\n}"
}
```

## JSToolProvider

`JSToolProvider` is the `@MainActor @Observable` registry. One per
process. It scans `bundlesDirectory` for files matching
`bundleFileExtension`, instantiates a `JSToolRuntime` per bundle,
and vends them via `tools() -> [AnyTool]`.

```swift
@MainActor
@Observable
public final class JSToolProvider {
    public init(
        bundlesDirectory: URL,
        httpClient: any HTTPClient = URLSessionHTTPClient(),
        bundleFileExtension: String = "aria-tool",
        globalName: String = "Aria"
    )

    public private(set) var loaded: [LoadedTool]
    public private(set) var errors: [LoadError]

    public func reload()
    public func save(_ bundle: JSToolBundle) throws -> JSToolBundle
    public func install(from sourceURL: URL) throws -> JSToolBundle
    public func uninstall(id: String)
    public func dryRun(bundle: JSToolBundle, input: JSONValue) async throws -> DryRunResult
    public func tools() -> [AnyTool]
}
```

`bundleFileExtension` defaults to `"aria-tool"` and `globalName`
defaults to `"Aria"`. Hosts that want a branded namespace pass them
explicitly (`bundleFileExtension: "niora-tool"`, `globalName:
"Niora"`). Plugin sources reference whichever global the host
configures — there's no default in the runtime itself, only the
value the embedder passes.

## JS global surface

The bridge object bound at the top of each plugin's `JSContext` is
the only way out to the host. Each property is assigned only when
the manifest declares the matching capability — that's the
permission-by-construction guarantee.

| Capability | Bound surface | Backed by |
| --- | --- | --- |
| `.http` | `Aria.http.get(url, opts?)`, `Aria.http.post(url, body, opts?)`, `Aria.http.request(url, opts)` | Injected `HTTPClient` (default `URLSessionHTTPClient`). |
| `.json` | `Aria.json.parse(text)`, `Aria.json.stringify(value)` | `JSONSerialization`. JS has these natively; the bridge exists for symmetry. |
| `.clipboard` | `Aria.clipboard.set(text)`, `Aria.clipboard.get()` | `UIPasteboard.general`. |
| `.share` | `Aria.share.present({ text, url })` | `UIActivityViewController` over the key window. |
| `.notify` | `Aria.notify.banner({ title, body })` | `UNUserNotificationCenter` immediate banner. Requires the host app to have requested notification authorization. |
| `.storage` | `Aria.storage.set(key, value)`, `Aria.storage.get(key)`, `Aria.storage.delete(key)` | `JSToolStorage` — a `UserDefaults` suite scoped to the tool id. |

The bridge object also carries two read-only metadata fields:
`Aria.toolId` and `Aria.toolVersion`, useful for logging or telemetry
inside the JS body.

All HTTP and share / notify calls return JS `Promise`s — author
plugins with `await` and `try / catch`.

## Permission-by-construction

Every capability the manifest doesn't claim corresponds to a
property that is never assigned on the bridge object. A plugin
that declares `["http", "json"]` and then tries to call
`Aria.clipboard.set(...)` fails synchronously inside the
`JSContext` with `TypeError: undefined is not an object` — not as a
runtime permission error.

This makes review trivial (the manifest tells you everything the
tool can reach) and makes accidental misuse impossible (calling an
undefined function in JS throws on the spot). The
`Tests/AriaToolsJSTests/` suite exercises the construction-time
absence to make sure the guarantee holds.

`Set<JSToolCapability>.userVisibleSideEffects` returns the subset
that produces a visible side effect (`.share`, `.notify`,
`.clipboard`) — handy for highlighting in your install UI.

## HTTPClient injection

`URLSessionHTTPClient` is the default, but any
`any HTTPClient`-conforming type works. Apps that need auth-aware
transport, certificate pinning, or request mocking pass a custom
client:

```swift
struct AuthInjectingHTTPClient: HTTPClient {
    let upstream: any HTTPClient
    let bearerToken: String

    func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var augmented = request
        augmented.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        return try await upstream.perform(augmented)
    }
}

let provider = JSToolProvider(
    bundlesDirectory: bundlesDir,
    httpClient: AuthInjectingHTTPClient(
        upstream: URLSessionHTTPClient(),
        bearerToken: token
    )
)
```

Same instance powers `AriaTools.HTTPTool`, so behaviour parity
between native and JS calls is automatic.

## Per-tool storage

`JSToolStorage` is a `UserDefaults` suite scoped to the tool id:

```swift
UserDefaults(suiteName: "avyra.toolsjs.storage.<toolId>")
```

Plugins can never read each other's keys, and uninstalling a tool
nukes the whole suite in one shot via `clearAll()`. The
`JSToolProvider.uninstall(id:)` path wires this automatically.

The dry-run path (`dryRun(bundle:input:)`, used by in-app
authoring UIs to "try this without saving") uses a `__dryrun_…`
suite that's cleared after every run — a broken in-progress
bundle can't leak keys into the eventual saved tool's real storage.

## Wiring into an agent

```swift
import Aria
import AriaApple
import AriaToolsJS

@MainActor
func makeAgent() throws -> Agent {
    let bundlesDir = try FileManager.default
        .url(for: .applicationSupportDirectory, in: .userDomainMask,
             appropriateFor: nil, create: true)
        .appendingPathComponent("aria-plugins", isDirectory: true)

    let plugins = JSToolProvider(bundlesDirectory: bundlesDir)

    return Agent(config: AgentConfig(
        provider: FoundationModelsProvider(),
        tools: plugins.tools(),
        systemPrompt: "You are a helpful assistant. Use tools when they apply.",
        threadId: "main"
    ))
}
```

The agent picks up the current `tools()` snapshot at construction
time. Re-create the agent (or rebuild `AgentConfig`) after
installs / uninstalls so the new surface reaches the next run.

## Workflow integration

`PluginToolStep` in [WorkflowKit](workflowkit.md) lets the same
`.aria-tool` bundles run as deterministic workflow steps —
bypassing the LLM entirely. `PluginToolBroker` is the bridge;
`JSPluginToolBroker` is the `JSToolProvider`-backed
implementation. Wire it into your compiler:

```swift
let compiler = WorkflowCompiler(
    broker: capabilityBroker,
    llmProvider: llmProvider,
    pluginToolBroker: JSPluginToolBroker(provider: plugins)
)
```

A workflow step naming `pluginID: "so.example.weather"` will
invoke the same `call(input)` function the chat agent calls. The
JSON input from `argsTemplate` interpolation becomes the function
argument; the resolved return value lands under the step's
`outputBinding`.

See [`docs/architecture.md`](architecture.md) for where
`AriaToolsJS` sits in the layered package layout and the main
[README](../README.md) for the broader SDK overview.
