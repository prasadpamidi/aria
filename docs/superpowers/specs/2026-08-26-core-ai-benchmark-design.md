# Core AI Benchmark Design

**Date:** 2026-08-26
**Status:** Approved

## Purpose

Determine whether Core AI should replace, complement, or remain behind Aria's existing MLX runtime for custom on-device language models used by Niora.

The benchmark must measure the runtime decision on a physical iPhone. A successful compile or a Mac-only result is insufficient because Niora's constraints are device memory, latency, heat, and battery-sensitive execution.

## Scope

This increment adds an isolated Xcode 27 benchmark runner under Aria. It compares matched Qwen3-0.6B models through Core AI and MLX without changing Aria's public provider API or Niora's production code.

The runner records:

- model preparation and load duration;
- time to first generated token;
- output tokens per second;
- total generation duration and token counts;
- peak resident memory during each trial;
- thermal state before and after each trial;
- runtime errors and cancellations; and
- pass/fail results for a fixed behavioral corpus.

## Non-goals

- Shipping Core AI in Niora.
- Replacing `LLMProvider` or `FoundationModelsProvider`.
- Designing Dynamic Profiles or multimodal meal logging.
- Committing model weights, exported `.aimodel` assets, caches, or benchmark reports.
- Claiming energy impact from thermal state alone. Instruments remains the source for detailed CPU, GPU, Neural Engine, and energy analysis.

## Repository Boundary

The benchmark lives in Aria because it evaluates an execution runtime that multiple host apps can consume. Niora remains unchanged until the evidence supports a production integration.

The benchmark is isolated from Aria's main `Package.swift` and normal Fastlane lanes. This preserves:

- the iOS 18 and macOS 15 package floor;
- Xcode 26 package builds and tests;
- simulator builds, where Core AI is not currently available; and
- Linux builds of the `Aria` core target.

The benchmark uses its own Xcode 27 project and an iOS 27 deployment target. It links the existing local Aria checkout for the MLX arm and Apple's `coreai-models` package for the Core AI arm.

## Runner Architecture

The runner is a minimal SwiftUI development app with four components:

1. `BenchmarkConfiguration` defines the corpus, trial count, model identifiers, context length, and generation limits.
2. `BenchmarkRuntime` is a benchmark-local protocol that normalizes setup, unload, and streaming generation without changing Aria's production protocols.
3. `BenchmarkCoordinator` runs one runtime at a time, samples process memory and thermal state, and produces immutable trial records.
4. `BenchmarkReportWriter` encodes a versioned JSON report and exposes it through the system share sheet.

Core AI uses `CoreAILanguageModel` and `LanguageModelSession` directly. MLX uses Aria's existing `MLXProvider`. The benchmark-local protocol prevents the spike from forcing the production `LanguageModel` adapter before its design is informed by measurements.

## Model Parity

The first comparison uses Qwen3-0.6B because both runtimes support it and its size is practical for repeated phone testing.

Both arms use:

- 4-bit weights using the closest supported runtime-specific representation;
- a 4,096-token context window;
- the same tokenizer family and instruction-tuned checkpoint lineage;
- identical prompts and maximum output-token limits; and
- deterministic sampling when both runtimes support it.

Compression formats and exported model hashes are recorded in the report. Results are labeled "matched configuration," not "identical binary," because Core AI palettization and MLX quantization are runtime-specific.

## Model Preparation

Model assets live under a gitignored benchmark assets directory.

Setup is explicit and separate from measured inference:

1. Export Qwen3-0.6B for iOS using Apple's `coreai-models` tooling.
2. Place the exported resource bundle in the ignored benchmark assets directory.
3. Download and cache the matching MLX model before starting trials.
4. Record source revision, model identifiers, hashes, sizes, compression, and context settings.

Network download and export time are not inference metrics. Core AI specialization time is recorded separately because it affects first-run product experience.

## Benchmark Corpus

The initial corpus has four categories:

- **Short response:** concise wellness-oriented instruction following.
- **Long context:** a near-window transcript followed by a grounded question.
- **Structured output:** a small guided schema representative of Niora decision packets.
- **Tool use:** deterministic tools and expected calls derived from Aria's existing task-evaluation fixtures.

Each case runs three measured trials per runtime after an unmeasured warm-up. Runtime order alternates by case to reduce thermal and cache-order bias. A cooldown gate pauses new trials while the device thermal state is serious or critical.

## Measurement Semantics

- **Load time:** start of runtime load through readiness for generation.
- **Time to first token:** generation request start through the first non-empty text delta.
- **Generation rate:** output tokens divided by time from first token through completion.
- **Total duration:** request start through terminal completion or error.
- **Peak resident memory:** highest sampled resident-memory value during the trial.
- **Thermal state:** `ProcessInfo` state captured before and after the trial.
- **Behavioral pass:** required content, forbidden content, expected structured decode, and expected tool call all succeed for the case.

Cold-process measurements are run separately after app relaunch and are not mixed into warm-trial aggregates.

## Report Format

Reports are Codable JSON with a schema version. They include:

- timestamp, device model, OS build, app build, and Xcode build;
- runtime and dependency revisions;
- model metadata and asset hashes;
- benchmark configuration;
- raw trial records, including failures;
- per-runtime aggregates using median and p95 where the sample count permits; and
- behavioral pass rates.

Raw trials remain authoritative. Aggregate calculations are deterministic and unit tested.

## Error Handling

The coordinator records a failed trial instead of aborting the full run. Typed failure categories cover missing assets, unsupported runtime, model load or specialization failure, generation failure, timeout, cancellation, structured-output failure, and invalid measurement.

The UI prevents a run when required assets are missing and shows the exact expected location. Cancellation stops the active generation, writes completed trial records, and marks the report incomplete.

## Testing and Verification

Deterministic unit tests cover:

- benchmark sequencing and alternating runtime order;
- warm-up exclusion;
- duration and generation-rate calculations;
- peak-memory sampling aggregation;
- cooldown behavior;
- failure recording and cancellation;
- report encoding and schema versioning; and
- behavioral scoring.

Runtime smoke tests require Xcode 27 and a physical iOS 27 device. They are opt-in and never run in standard Aria CI. Aria's existing Xcode 26 Fastlane build, test, and quality lanes must continue to pass unchanged.

## Decision Rule

The benchmark concludes with one of three recommendations:

1. **Adopt Core AI:** Core AI materially improves latency, throughput, or memory without unacceptable behavioral regression.
2. **Retain MLX:** Core AI offers no material product advantage or introduces unacceptable integration/runtime constraints.
3. **Route by model or device:** each runtime wins for a distinct supported model, hardware class, or workload.

No single metric decides the result. A runtime must meet the behavioral corpus first; performance improvements from a runtime that fails required structured output or tool use do not justify adoption.

## Follow-on Work

If Core AI is adopted or selectively routed, the next increment designs an iOS 27 `LanguageModel` adapter in Aria. That work will reuse `LanguageModelSession` while preserving Aria's context selection, memory provenance, workflow, observability, replay, and cross-platform `LLMProvider` boundary.
