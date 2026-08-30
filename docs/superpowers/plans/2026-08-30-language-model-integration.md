# iOS 27 Language Model Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to execute this plan task-by-task.

**Goal:** Let `FoundationModelsProvider` run any iOS 27 `LanguageModel`, including `CoreAILanguageModel`, without changing Aria's public provider type, portable core, or existing iOS 26 call sites.

**Architecture:** Keep `FoundationModelsProvider` non-generic and type-erase session construction behind an internal sendable factory. The existing initializer installs a system-model factory; an Xcode 27-only initializer captures a concrete `LanguageModel`. Text, selected-tool, and structured generation all use that factory. A nested opt-in package proves Core AI on a physical device without adding `coreai-models` to Aria's root graph.

**Tech Stack:** Swift 6.3/6.4, Foundation Models, XCTest, Swift Package Manager, Fastlane, Core AI, Qwen3-0.6B, Apple's `coreai-models` revision `de31ba508895c7aa3bdcc57f8837a23f13316871`.

**Spec:** `docs/superpowers/specs/2026-08-30-language-model-integration-design.md`

## Global Constraints

- Keep `Sources/Aria` free of Apple frameworks and the root `Package.swift` free of `coreai-models`.
- Preserve `FoundationModelsProvider()` and iOS 26 behavior.
- Guard iOS 27 symbols with `#if compiler(>=6.4)`; Xcode 26.6 uses Swift 6.3.3.
- Never silently replace an injected model with `SystemLanguageModel.default`.
- Validate the Aria capabilities that map to Apple capabilities: vision, structured/guided generation, and tools/tool calling.
- Keep the Core AI proof under `Examples/CoreAIProof`, outside the root package graph.
- Never commit model bundles, compiled caches, or proof reports.
- Use Fastlane for root-package build, test, and quality commands.

---

### Task 1: Centralize session construction behind a deterministic seam

**Files:**

- Create: `Sources/AriaApple/Providers/FoundationModelsSessionFactory.swift`
- Modify: `Sources/AriaApple/Providers/FoundationModelsProvider.swift:29-37,81-86,177-193,245-311`
- Modify: `Sources/AriaApple/Providers/FoundationModelsStructured.swift:64-94`
- Modify: `Tests/AriaAppleTests/Providers/FoundationModelsProviderTests.swift:144-220`
- Modify: `Tests/AriaAppleTests/Providers/FoundationModelsStructuredTests.swift:18-43`
- Create if shared helpers are needed: `Tests/AriaAppleTests/Providers/FoundationModelsSessionFactoryTestSupport.swift`

- [x] **Step 1: Add failing tests for all session paths**

Add an outcome-based test factory. Its validator throws one error when the provider requests the expected requirements and a different error for the wrong requirements. Assert the error preserved by the public stream, not the test double's internal state:

```swift
enum SessionFactoryTestError: Error {
    case expectedRequirementsReached
    case unexpectedRequirements(FoundationModelsSessionRequirements)
    case builderReached
}

func testFactory(
    expecting expected: FoundationModelsSessionRequirements
) -> FoundationModelsSessionFactory {
        FoundationModelsSessionFactory(
            validate: { actual in
                guard actual == expected else {
                    throw SessionFactoryTestError.unexpectedRequirements(actual)
                }
                throw SessionFactoryTestError.expectedRequirementsReached
            },
            build: { _, _, _ in
                throw SessionFactoryTestError.builderReached
            }
        )
}
```

Add tests named:

- `testTextStreamUsesConfiguredFactory` expecting `[]`;
- `testTextStreamRequestsToolCallingWhenTypedToolsAreOffered` expecting `.toolCalling`;
- `testStructuredStreamRequestsGuidedGeneration` expecting `.guidedGeneration`.

Each consumes the returned stream and requires `AgentError.providerFailed` whose underlying `ErrorBox.typeName` is `SessionFactoryTestError`. Also require the message to identify `expectedRequirementsReached`, so a wrong requirement or an accidentally reached builder cannot satisfy the assertion. No real model runs.

Run:

```bash
/Users/prasadmini/.rbenv/shims/bundle exec fastlane package_tests
```

Expected: compilation fails because the factory, requirements, and internal provider initializer do not exist.

- [x] **Step 2: Implement the factory**

Create:

```swift
#if canImport(FoundationModels)
    import Aria
    import FoundationModels

    @available(iOS 26.0, macOS 26.0, *)
    struct FoundationModelsSessionRequirements: OptionSet, Sendable, Equatable {
        let rawValue: UInt8
        static let vision = Self(rawValue: 1 << 0)
        static let guidedGeneration = Self(rawValue: 1 << 1)
        static let toolCalling = Self(rawValue: 1 << 2)
    }

    @available(iOS 26.0, macOS 26.0, *)
    struct FoundationModelsSessionFactory: Sendable {
        typealias Validator = @Sendable (FoundationModelsSessionRequirements) throws -> Void
        typealias Builder = @Sendable (
            [any FoundationModels.Tool],
            Transcript,
            FoundationModelsSessionRequirements
        ) throws -> LanguageModelSession

        init(validate: @escaping Validator, build: @escaping Builder) {
            self.validate = validate
            self.build = build
        }

        static let systemDefault = Self(
            validate: { _ in try FoundationModelsProvider.checkAvailability() },
            build: { tools, transcript, _ in
                LanguageModelSession(tools: tools, transcript: transcript)
            }
        )

        func makeSession(
            tools: [any FoundationModels.Tool],
            transcript: Transcript,
            requirements: FoundationModelsSessionRequirements
        ) throws -> LanguageModelSession {
            try self.validate(requirements)
            return try self.build(tools, transcript, requirements)
        }

        private let validate: Validator
        private let build: Builder
    }
#endif
```

Make the existing public initializer delegate to an internal initializer with `.systemDefault`. Store `sessionFactory`, and keep `checkAvailability()` as the system factory's validator so existing prompt probes remain source-compatible.

Replace the text-path constructor with:

```swift
var requirements: FoundationModelsSessionRequirements = []
if !registrableTools.isEmpty { requirements.insert(.toolCalling) }
let session = try self.sessionFactory.makeSession(
    tools: registrableTools,
    transcript: transcript,
    requirements: requirements
)
```

Replace the structured-path constructor with the same call, starting from `[.guidedGeneration]` and adding `.toolCalling` when tools are present.

- [x] **Step 3: Verify and commit**

```bash
/Users/prasadmini/.rbenv/shims/bundle exec fastlane package_tests
git add Sources/AriaApple/Providers/FoundationModelsSessionFactory.swift Sources/AriaApple/Providers/FoundationModelsProvider.swift Sources/AriaApple/Providers/FoundationModelsStructured.swift Tests/AriaAppleTests/Providers
git commit -m "Centralize Foundation Models session construction"
```

Expected: all package tests pass; real-model tests may skip when unavailable.

---

### Task 2: Add the iOS 27 model initializer and capability validation

**Files:**

- Modify: `Sources/AriaApple/Providers/FoundationModelsSessionFactory.swift`
- Modify: `Sources/AriaApple/Providers/FoundationModelsProvider.swift:27-41`
- Create: `Tests/AriaAppleTests/Providers/FoundationModelsLanguageModelTests.swift`

- [x] **Step 1: Add Xcode 27-only failing tests**

Under `#if canImport(FoundationModels) && compiler(>=6.4)` and `@available(iOS 27.0, macOS 27.0, *)`, add:

- `testInjectedInitializerKeepsDeclaredCapabilities`, injecting `SystemLanguageModel.default` through the new generic API;
- `testValidationRejectsUnsupportedGuidedGeneration`;
- `testValidationRejectsRequestedToolCalling`;
- `testValidationAcceptsVisionGuidedGenerationAndToolCalling`.

Construct Apple capability sets with `LanguageModelCapabilities([])` and `LanguageModelCapabilities([.vision, .guidedGeneration, .reasoning, .toolCalling])`. Require failures to be `AgentError.configurationInvalid`.

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer /Users/prasadmini/.rbenv/shims/bundle exec fastlane package_tests
```

Expected: compilation fails because the initializer and validator do not exist.

- [x] **Step 2: Implement the generic initializer**

Add:

```swift
#if compiler(>=6.4)
    @available(iOS 27.0, macOS 27.0, *)
    public init<Model: LanguageModel>(
        model: Model,
        defaultInstructions: String? = nil,
        capabilities: ProviderCapabilities,
        typedTools: [FoundationModelsToolFactory] = []
    ) {
        self.init(
            defaultInstructions: defaultInstructions,
            capabilities: capabilities,
            typedTools: typedTools,
            sessionFactory: .injected(model: model, declaredCapabilities: capabilities)
        )
    }
#endif
```

Add an iOS 27 factory extension that captures `model`, captures `model.capabilities`, and builds:

```swift
LanguageModelSession(model: model, tools: tools, transcript: transcript)
```

Implement:

```swift
static func validate(
    declared: ProviderCapabilities,
    available: LanguageModelCapabilities,
    requested: FoundationModelsSessionRequirements
) throws
```

Build the required set from requested requirements plus:

- `declared.supportsVision -> .vision`;
- `declared.supportsStructuredOutput -> .guidedGeneration`;
- `declared.supportsToolUse -> .toolCalling`.

Throw `AgentError.configurationInvalid("Language model does not support: ...")` listing every missing capability. Do not reject extra Apple capabilities and do not add reasoning to `ProviderCapabilities`.

- [x] **Step 3: Verify stable and beta toolchains**

```bash
/Users/prasadmini/.rbenv/shims/bundle exec fastlane package_tests
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer /Users/prasadmini/.rbenv/shims/bundle exec fastlane package_tests
```

Expected: stable Xcode excludes Swift 6.4 declarations; Xcode 27 compiles them; all runnable tests pass.

- [x] **Step 4: Commit**

```bash
git add Sources/AriaApple/Providers/FoundationModelsSessionFactory.swift Sources/AriaApple/Providers/FoundationModelsProvider.swift Tests/AriaAppleTests/Providers/FoundationModelsLanguageModelTests.swift
git commit -m "Accept iOS 27 language models in AriaApple"
```

---

### Task 3: Document the model-neutral boundary and Niora insertion points

**Files:**

- Modify: `README.md:276-340`
- Modify: `docs/layers/03-providers.md:247-270`
- Modify: `docs/platform-boundary.md:80-126`

- [x] **Step 1: Add the public usage example**

Show a consumer importing `CoreAILanguageModels`, loading `CoreAILanguageModel(resourcesAt:)`, and passing it to:

```swift
let provider = FoundationModelsProvider(
    model: model,
    capabilities: ProviderCapabilities(
        modelIdentifier: "coreai.qwen3-0.6b",
        supportsToolUse: model.capabilities.contains(.toolCalling),
        supportsStructuredOutput: model.capabilities.contains(.guidedGeneration)
    )
)
```

State that the consumer owns the Core AI dependency, model assets, device eligibility, and fallback.

- [x] **Step 2: Record provider behavior**

Document that:

- system availability applies only to the default initializer;
- injected load/executor failures use the existing `providerFailed(..., underlying:)` path;
- capability contradictions fail before session generation;
- no automatic fallback occurs;
- Core AI stays out of Aria's root package.

- [x] **Step 3: Name Niora's future seams**

Document these exact insertion points:

- `iOS/Niora/Services/AI/Runtime/AgentWiring.swift:63`;
- `iOS/Niora/LLMs/Aria/AriaContext.swift:557`;
- `iOS/Niora/Services/AICapabilityRouter.swift:96`.

Specify a developer-only custom-local subtype beneath `.useLocal` after simulator compatibility is resolved. Do not add a cloud/server resolution. Note that `FoundationModelsWorkflowProvider` stays separate until migrated to Aria's `LLMProvider` surface.

- [x] **Step 4: Verify and commit**

Verification: stable and Xcode 27 package suites pass. Focused strict lint is
clean for the changed Swift source; the repository-wide strict lane remains
blocked by 40 pre-existing violations outside this work.

```bash
/Users/prasadmini/.rbenv/shims/bundle exec fastlane lint strict:true
/Users/prasadmini/.rbenv/shims/bundle exec fastlane package_tests
git add README.md docs/layers/03-providers.md docs/platform-boundary.md
git commit -m "Document custom LanguageModel injection"
```

---

### Task 4: Add an isolated Core AI device proof

**Files:**

- Create: `Examples/CoreAIProof/Package.swift`
- Create: `Examples/CoreAIProof/README.md`
- Create: `Examples/CoreAIProof/Tests/CoreAIProofTests/CoreAIProofTests.swift`
- Create: `Examples/CoreAIProof/Tests/CoreAIProofTests/ProofTool.swift`
- Create: `Examples/CoreAIProof/Tests/CoreAIProofTests/Resources/README.md`
- Modify: `.gitignore`

- [x] **Step 1: Create the nested package**

Use a Swift 6.4 manifest with iOS 27 platform, local dependency `.package(path: "../..")`, and:

```swift
.package(
    url: "https://github.com/apple/coreai-models.git",
    revision: "de31ba508895c7aa3bdcc57f8837a23f13316871"
)
```

Create one test target depending on Aria, AriaApple, AriaTesting, and `.product(name: "CoreAILM", package: "coreai-models")`, with `.copy("Resources")`.

From the Aria root run:

```bash
swift package show-dependencies
```

Expected: `coreai-models` is absent from the root graph. This read-only graph inspection is the narrow exception to the Fastlane rule.

- [x] **Step 2: Ignore proof assets and output**

Add:

```gitignore
Examples/CoreAIProof/Tests/CoreAIProofTests/Resources/Qwen3-0.6B/
Examples/CoreAIProof/Reports/
Examples/CoreAIProof/.build/
Examples/CoreAIProof/.swiftpm/
Examples/CoreAIProof/Package.resolved
```

The resource README must include Apple's export command:

```bash
uv run coreai.llm.export Qwen/Qwen3-0.6B --platform iOS --output-dir ./exported-models
```

and direct the exported resource folder to `Tests/CoreAIProofTests/Resources/Qwen3-0.6B/`.

- [x] **Step 3: Add proof code**

Add a deterministic `GenerableTool` named `coreai_aria_proof` whose JSON output always includes `COREAI_ARIA_TOOL_OK`. Confirm its method signature against `Sources/Aria/Providers/Tool.swift` before writing it.

Load:

```swift
let resources = try XCTUnwrap(
    Bundle.module.url(
        forResource: "Qwen3-0.6B",
        withExtension: nil,
        subdirectory: "Resources"
    )
)
let model = try await CoreAILanguageModel(resourcesAt: resources, mode: .eager)
```

Build declared capabilities from `model.capabilities`, register the proof tool, and inject the model into `FoundationModelsProvider`.

- [x] **Step 4: Add four opt-in cases**

Gate the suite with `COREAI_ARIA_PROOF=1`. With the gate enabled, missing resources must fail clearly.

Add:

- `testTextStreamsThroughAria`: require start, text, and stop events;
- `testStructuredOutputThroughAria`: require partial output and a final two-field `@Generable` value;
- `testToolExecutionThroughAria`: require the tool event and marker;
- `testTaskEvalRecordsDiagnosticResult`: run one `TaskCase` for one trial, print the summary, and reject only infrastructure errors.

Measure each with `ContinuousClock` and print timings. Add no performance thresholds and make no MLX comparison.

- [⚠️] **Step 5: Document and compile for a physical target**

`build-for-testing` succeeds for generic iOS with Xcode 27. Running the four
cases remains pending because the ignored Qwen3-0.6B resources and a connected
iOS 27 device are not present in this worktree/session.

The proof README must cover Xcode 27, an iOS 27 physical device, model export/copy, the environment gate, the upstream simulator limitation, and the fact that timings are diagnostics.

Compile without running:

```bash
cd Examples/CoreAIProof
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild build-for-testing -scheme CoreAIProof-Package -destination 'generic/platform=iOS' -skipPackagePluginValidation -skipMacroValidation
```

Expected: build-for-testing succeeds. Then open `Package.swift` in Xcode, select a connected physical iPhone, set `COREAI_ARIA_PROOF=1` on the test scheme, and run all four tests. Expected: all finish and the console prints timing plus a `TaskEval` summary.

- [x] **Step 6: Verify isolation and commit**

```bash
cd ../..
/Users/prasadmini/.rbenv/shims/bundle exec fastlane package_tests
git status --short
```

Expected: root tests pass and no model, report, nested build, or nested resolution file appears.

```bash
git add .gitignore Examples/CoreAIProof
git commit -m "Add isolated Core AI device proof"
```

---

### Task 5: Final verification and review

**Files:**

- Update this checklist immediately as each step changes state.

- [ ] **Step 1: Run regression gates**

```bash
/Users/prasadmini/.rbenv/shims/bundle exec fastlane package_tests
/Users/prasadmini/.rbenv/shims/bundle exec fastlane lint strict:true
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer /Users/prasadmini/.rbenv/shims/bundle exec fastlane package_tests
```

Expected: stable and beta suites plus lint pass.

- [ ] **Step 2: Verify isolation and patch hygiene**

```bash
rg -n "coreai-models|CoreAILanguageModels" Package.swift Sources Tests
git diff --check
git status --short
```

Expected: no production/root references, a clean whitespace check, and only intended files.

- [ ] **Step 3: Conduct focused review**

Verify:

- no direct session constructor remains in the provider text/structured paths;
- system availability is not applied to injected models;
- underlying model errors remain in `ErrorBox`;
- capability failures happen before the builder;
- cancellation still maps to `.cancelled` without retry;
- Swift 6.3 cannot see Swift 6.4 symbols;
- the proof is absent from the root graph;
- Niora source and dependencies remain unchanged.

- [ ] **Step 4: Address every finding and rerun affected gates**

Apply each fix test-first and mark its checklist item immediately.

- [ ] **Step 5: Commit review adjustments if any**

```bash
git add -A
git commit -m "Finish iOS 27 language model integration"
```

Skip when review produces no changes.

## Success Criteria

- [ ] Existing provider consumers compile unchanged on Xcode 26.6.
- [ ] Xcode 27 consumers can inject any concrete `LanguageModel`.
- [ ] Text, executable-tool, and structured paths use the injected factory.
- [ ] Unsupported declared/requested capabilities fail before generation.
- [ ] Injected models never silently fall back to the system model.
- [ ] Stable tests/lint and Xcode 27 compilation pass.
- [ ] Qwen3-0.6B completes all four physical-device proof cases.
- [ ] Niora's future routing seams are documented without changing its package graph.

## Documentation Updates Required

- [ ] `README.md` includes custom-model injection.
- [ ] `docs/layers/03-providers.md` explains behavior and Niora seams.
- [ ] `docs/platform-boundary.md` records dependency ownership.
- [ ] `Examples/CoreAIProof/README.md` contains complete device steps.
