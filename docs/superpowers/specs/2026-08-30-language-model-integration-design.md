# Language Model Integration Design

**Date:** 2026-08-30
**Status:** Approved

## Purpose

Make Apple's iOS 27 `LanguageModel` protocol a first-class execution seam in Aria so Niora can use Apple's system model, a Core AI custom model, or another conforming model without changing its agent, memory, tool, or workflow layers.

This increment is integration-first. It proves the production architecture with a lightweight Core AI device smoke test. Comparative benchmarking is deferred until Niora has a concrete runtime-selection decision.

## Product Advantage

Core AI controls how a custom model runs. Aria controls what makes that model useful inside Niora:

- context budgeting and history selection;
- capability and model routing;
- relevant tool selection;
- memory provenance and retrieval;
- workflow and agent execution;
- fallback behavior;
- observability, evaluation, and replay.

The integration must not imply that every Core AI call belongs behind Aria. Small one-shot features with no history, tools, routing, or memory may continue to use Foundation Models directly.

## Scope

This increment:

1. Extends `FoundationModelsProvider` with an iOS 27 initializer accepting any concrete `LanguageModel`.
2. Preserves the existing iOS 26 system-model initializer and public type name.
3. Uses the injected model for text streaming, executable tools, and structured responses.
4. Adds deterministic tests around model-independent session construction.
5. Adds an opt-in Xcode 27 device smoke test using `CoreAILanguageModel` and Qwen3-0.6B.
6. Documents how a Niora provider route will inject a custom model after the smoke test passes.

## Non-goals

- Replacing Aria's cross-platform `LLMProvider` protocol with Apple's protocol.
- Adding Core AI or `coreai-models` to Aria's root package dependencies.
- Shipping a Core AI model in Niora in this increment.
- Removing MLX.
- Adopting Dynamic Profiles, multimodal prompts, or Private Cloud Compute.
- Building a benchmark application or selecting a default custom-model runtime.

## Architecture

The ownership boundary is:

```text
Niora
  domain behavior, permissions, feature routing
        |
Aria
  context, memory, tools, workflows, evaluation
        |
FoundationModels.LanguageModel
        |
Apple system model | Core AI model | other conforming model
```

Aria's portable core remains unchanged. The new API lives only in `AriaApple`, alongside the existing Foundation Models provider.

## Provider Design

`FoundationModelsProvider` remains a non-generic public struct. Making the type generic would ripple through Niora's `any LLMProvider` wiring and create an unnecessary source break.

Instead, the provider stores an internal, sendable session factory. The existing initializer configures that factory with `SystemLanguageModel.default`. A new iOS 27 initializer is generic only at initialization:

```swift
@available(iOS 27.0, macOS 27.0, *)
public init<Model: LanguageModel>(
    model: Model,
    defaultInstructions: String? = nil,
    capabilities: ProviderCapabilities,
    typedTools: [FoundationModelsToolFactory] = []
)
```

The initializer captures the concrete model in a closure that creates the non-generic `LanguageModelSession`. This preserves the provider's existing stored type and `LLMProvider` conformance while satisfying Foundation Models' concrete-model requirement.

The session factory receives the accepted typed tools and transcript. Every path that currently constructs a `LanguageModelSession` must use the same factory, including:

- ordinary text streaming;
- executable-tool streaming; and
- typed structured responses.

This prevents the custom model from silently reverting to `SystemLanguageModel.default` on one response path.

## Availability and Capabilities

The existing provider checks `SystemLanguageModel.default.availability`. That check remains on the system-model initializer.

An injected model does not inherit that check. Its load or generation failures propagate through the existing provider error path. Aria does not invent a second availability abstraction until two non-system model implementations demonstrate a shared need.

Callers provide Aria's `ProviderCapabilities` for an injected model. The provider validates obvious contradictions against `LanguageModel.capabilities` where Aria has a corresponding declaration: vision, guided generation/structured output, and tool calling. Aria does not currently declare reasoning support, so the provider does not invent a new portable capability solely for this adapter. Unsupported requested behavior fails before generation with a typed configuration error.

## Dependency Boundary

Aria does not depend on Apple's `coreai-models` Swift package. It depends only on the system `FoundationModels` protocol that `CoreAILanguageModel` conforms to.

This is required because:

- `coreai-models` has an iOS 27 and macOS 27 package floor;
- Core AI is unavailable in the iOS Simulator SDK; and
- the upstream package currently fails simulator builds when `CoreAILM` is linked.

The generic initializer lets a consumer that can safely own the dependency inject `CoreAILanguageModel` without pulling Core AI into every Aria consumer.

## Core AI Proof

The proof is an opt-in, device-only fixture outside Aria's normal product graph. It:

1. Uses Xcode 27 and an iOS 27 physical device.
2. Loads an ignored Qwen3-0.6B Core AI resource bundle.
3. Constructs `CoreAILanguageModel` in the fixture.
4. Injects it into `FoundationModelsProvider`.
5. Runs one text case, one structured-output case, and one deterministic tool case through Aria.
6. Records the existing `TaskEval` result and basic timing for diagnostic context.

The proof answers whether Core AI participates correctly in Aria. It does not claim runtime superiority over MLX.

Model assets, caches, and reports are ignored and never committed. Model download, export, and specialization are explicit setup steps.

## Niora Adoption Boundary

Niora does not add `coreai-models` to its main app target while the upstream simulator issue remains open.

After the device proof succeeds and the dependency can coexist with normal simulator builds, Niora adds a developer-only provider route in its existing AI capability routing layer. That route injects a Core AI model into the same Aria provider used by agent and workflow features.

The first production candidate must be a flow that benefits from Aria's context, tools, memory, or fallback behavior. A simple one-shot transformation is not sufficient justification for migration.

## Error Handling

The provider preserves existing stream termination and typed Aria errors. New failure cases are handled as follows:

- contradictory declared capabilities fail configuration before a request;
- model load, specialization, or executor failures propagate with their underlying error;
- unsupported transcript content is surfaced rather than silently removed;
- tool registration rejection remains visible through the current diagnostic event path; and
- cancellation terminates the stream without retrying on another model unless the caller explicitly configured tiered fallback.

Fallback remains an Aria routing concern. The provider does not silently replace an injected model with the system model.

## Testing

Deterministic `AriaAppleTests` cover:

- the existing initializer still builds system-model sessions;
- the iOS 27 initializer uses the injected session factory;
- text, tool, and structured paths all request sessions from that factory;
- capabilities map and contradictions fail early;
- injected-model errors are preserved; and
- existing iOS 26 behavior remains unchanged.

The device proof is opt-in and excluded from standard CI. Normal verification remains:

- Aria package tests and quality checks with stable Xcode;
- an Xcode 27 compile of the new availability-gated API; and
- the physical-device Core AI smoke test when model assets are present.

## Success Criteria

The increment is complete when:

- existing Aria consumers require no source changes;
- stable Xcode package tests and Linux-safe boundaries still pass;
- Xcode 27 compiles the generic `LanguageModel` initializer;
- all session creation paths honor the injected model;
- the Qwen3-0.6B device proof completes text, structured, and tool cases through Aria; and
- Niora's future injection point is documented without changing its production dependency graph.

## Deferred Benchmark Trigger

A comparative Core AI versus MLX benchmark is created only if one of these decisions becomes real:

- choosing the default runtime for the same model;
- dropping MLX support;
- routing by device class;
- meeting a documented latency, memory, thermal, or energy target; or
- comparing materially different Core AI and MLX model behavior for a Niora feature.

Until then, Aria's existing task evaluation and smoke timing provide sufficient integration evidence.
