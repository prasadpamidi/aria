# Core AI through Aria device proof

This opt-in package verifies that a Core AI `CoreAILanguageModel` can use Aria's
text streaming, guided generation, typed tools, and task-evaluation surfaces. It
is deliberately outside Aria's root package graph and is not a benchmark.

## Requirements

- Xcode 27 or newer.
- A physical iPhone running iOS 27 or newer.
- `uv` and a checkout of Apple's
  [`coreai-models`](https://github.com/apple/coreai-models) repository.

Core AI is unavailable in the iOS Simulator SDK. The pinned upstream package
cannot currently compile when a Core AI product is linked for a simulator
destination, so use a generic iOS or connected-device destination only.

## Prepare the model

From the `coreai-models` checkout, export Qwen3-0.6B:

```bash
uv run coreai.llm.export Qwen/Qwen3-0.6B --platform iOS --output-dir ./exported-models
```

Copy the exported model resource folder to:

```text
Tests/CoreAIProofTests/Resources/Qwen3-0.6B/
```

The copied directory is ignored by Git. It must contain the export's
`metadata.json`, model asset, and tokenizer resources.

## Compile the proof

From this directory:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild build-for-testing \
  -scheme CoreAIProof-Package \
  -destination 'generic/platform=iOS' \
  -skipPackagePluginValidation \
  -skipMacroValidation
```

## Run on a device

1. Open this directory's `Package.swift` in Xcode 27.
2. Select a connected iPhone running iOS 27 or newer.
3. Add `COREAI_ARIA_PROOF=1` to the test scheme's environment variables.
4. Run all `CoreAIProofTests` tests.

Without the environment gate, the suite skips before looking for model assets.
With it enabled, missing resources fail with the expected destination path.

Each case prints a `ContinuousClock` duration, and the task-evaluation case
prints its `TaskEval` summary. These values are diagnostic evidence only: there
are no performance thresholds and no Core AI versus MLX comparison.
