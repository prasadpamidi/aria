# AGENTS.md — Guidance for AI Agents Working on Aria

This document is the primary guide for AI coding assistants (Claude, Copilot, Cursor, Codex, etc.) contributing to the Aria codebase. It describes the project, the architecture, the conventions, and the rules that contributors — human or otherwise — must follow.

> **Independence statement (read this first).** Aria is an independent design and implementation. Do not copy, paste, or transliterate code or documentation from LangChain.js, LangGraph.js, Python LangChain, LlamaIndex, or any other agent/LLM framework. See [NOTICE.md](NOTICE.md) for the full statement. If you are unsure whether something would constitute copying, ask before producing it.

## What Aria is

Aria is a Swift library for building agent-driven applications that run on-device on Apple platforms. It provides a tool-calling agent runtime, a clean abstraction over local LLMs (FoundationModels, MLX, Core ML), memory primitives, and an optional graph orchestration layer.

The core (`Aria` target) is platform-agnostic and builds on Linux. Apple-specific implementations live in `AriaApple`.

For the full design, read `docs/` in this order:

1. `docs/overview.md`
2. `docs/principles.md`
3. `docs/architecture.md`
4. `docs/platform-boundary.md`
5. `docs/layers/01-foundation.md` through `docs/layers/06-stategraph.md`
6. `docs/decisions/` for ADRs

## Project layout

```
aria/
├── docs/                       Architecture & design documentation
├── Sources/
│   ├── Aria/                   Layer 1–6, platform-agnostic (Linux-buildable)
│   ├── AriaTesting/            Mocks, fixtures, test helpers
│   ├── AriaApple/              Apple-specific implementations
│   └── AriaTools/              Cross-platform tool implementations
├── Tests/
│   ├── AriaTests/              Run on Linux + Apple
│   └── AriaAppleTests/         Run on Apple only
├── Examples/
│   ├── AriaCLI/                CLI demo (executable target)
│   └── SampleApp/              SwiftUI starter (separate Xcode project)
├── Package.swift
├── README.md
├── LICENSE
├── NOTICE.md                   Clean-room IP statement
├── CONTRIBUTING.md
├── AGENTS.md                   (this file)
└── CLAUDE.md                   Claude Code-specific notes
```

## Build and test commands

### Swift Package (CLI)

```bash
swift build                              # build all targets
swift build --target Aria                # build only platform-agnostic core
swift test                               # all tests
swift test --filter AriaTests            # core tests (Linux-safe)
swift run AriaCLI                        # CLI demo
```

### AriaSample (iOS app)

```bash
# Open in Xcode
open Examples/SampleApp/AriaSample.xcodeproj

# Build from CLI
xcodebuild build \
  -project Examples/SampleApp/AriaSample.xcodeproj \
  -scheme AriaSample \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

### Fastlane (preferred for routine work)

```bash
# Package
bundle exec fastlane package_build       # swift build
bundle exec fastlane package_tests       # swift test
bundle exec fastlane core_tests          # swift test --filter AriaTests
bundle exec fastlane cli_demo            # swift run AriaCLI

# Sample app
bundle exec fastlane sample_build        # build AriaSample on iOS Simulator
bundle exec fastlane sample_tests        # run AriaSample tests on iOS Simulator
bundle exec fastlane sample_build device:'iPhone 17 Pro' clean:true

# Code quality
bundle exec fastlane format              # SwiftFormat in place
bundle exec fastlane format lint:true    # SwiftFormat check only
bundle exec fastlane lint                # SwiftLint
bundle exec fastlane lint fix:true       # SwiftLint --fix
bundle exec fastlane quality             # format --lint + lint
bundle exec fastlane quality fix:true    # auto-fix both

# CI shortcuts
bundle exec fastlane ci_quality          # used by the GitHub Actions quality job
bundle exec fastlane ci_build_test       # package_tests + sample_build
```

If `fastlane` is on your PATH (via rbenv or system gems), the `bundle exec` prefix is optional; `fastlane <lane>` works directly. CI uses `bundle exec` for reproducibility.

### Local tooling setup (one-time)

```bash
brew bundle                  # installs swiftformat, swiftlint
bundle install               # installs fastlane (or use system fastlane)
./scripts/install-hooks.sh   # enables the pre-commit hook
```

The pre-commit hook runs `swiftformat --lint` and `swiftlint --strict` against staged Swift files and blocks the commit if either fails. Bypass with `git commit --no-verify` only when intentional.

## The platform boundary (CRITICAL)

The `Aria` target compiles, links, and tests on Linux. This is the single most important architectural rule.

**Banned in `Aria`:**
- `import UIKit`, `import AppKit`, `import SwiftUI`, `import WatchKit`
- `import FoundationModels`, `import CoreML`, `import NaturalLanguage`
- `import Combine` (use `AsyncSequence`)
- `import OSLog`, `os_log` (use `swift-log`)
- `import EventKit`, `import HealthKit`, `import Contacts`, `import CoreLocation`
- `import AVFoundation`, `import Photos`
- `import MLX`, `import MLXNN`
- `@Generable` and other FoundationModels macros
- `URLSession` directly (use `HTTPClient` protocol)
- `NSRegularExpression` (use Swift `Regex`)
- `DispatchQueue` (use Swift Concurrency)

**Allowed in `Aria`:**
- Swift Standard Library
- Swift Concurrency (`Task`, `actor`, `AsyncSequence`, `AsyncStream`, `AsyncThrowingStream`, `Sendable`)
- `Codable`, `Data`, `URL`, `Date`, `UUID`, `ContinuousClock`, `Duration`
- `Logger` from `swift-log`
- `swift-collections`
- Swift `Regex`

If you find yourself wanting an Apple-only API in `Aria`, the answer is one of:
1. Define a protocol in `Aria` and put the implementation in `AriaApple`.
2. Move the type to `AriaApple` entirely.
3. Reconsider whether the feature belongs in core.

See `docs/platform-boundary.md` for the full rule set.

## Architectural principles

Summarized from `docs/principles.md`:

1. **Layers, strictly.** A layer depends only on layers below it. No upward references.
2. **Protocols first, defaults included.** Every infrastructure concern is a protocol with at least one in-memory implementation in core.
3. **Platform-agnostic core.** Linux-buildable. See above.
4. **Streaming is the default.** `AsyncThrowingStream` is the universal output. `invoke` is a convenience over `stream`.
5. **Typed everything.** Errors, events, configs are enums or structs. No `[String: Any]` except as user-supplied metadata.
6. **Composition via Runnable.** Anything that maps Input → Output conforms to `Runnable<Input, Output>`.
7. **Middleware over inheritance.** Cross-cutting concerns are decorators or middleware hooks.
8. **`Sendable` everywhere.** Strict concurrency catches bugs and portability issues.
9. **Errors are values, not exceptions.** Throw for unrecoverable failures; emit events for expected outcomes.
10. **No global state, no singletons.** Inject dependencies.
11. **Small foundation, additive everything else.** Optional layers stay optional.
12. **Observability is hooks, not platform.** Aria does not build a tracing platform.

## Code style

- Swift 5.10+ syntax; Swift 6 concurrency mode where supported.
- 4-space indentation. No tabs.
- `public` for API; default to `internal` otherwise.
- Type names: `UpperCamelCase`. Properties, methods, parameters: `lowerCamelCase`.
- One type per file when the type is non-trivial (>~30 lines). Small related types may share a file.
- `MARK: -` comments to organize file sections.
- Documentation comments (`///`) on all public APIs.
- No emoji in code, comments, or commit messages.
- No trailing whitespace.

## Concurrency

- Mutable shared state lives in `actor`s.
- All public types are `Sendable` unless they are explicitly mutable (rare).
- Use `AsyncStream` and `AsyncThrowingStream` for streaming; never custom callback APIs.
- `@MainActor` is for UI code (which lives in consumers, not Aria). Do not mark library code `@MainActor`.

## Testing

- Tests for `Aria` and `AriaTests` must run on Linux. If a test requires an Apple framework, it belongs in `AriaAppleTests`.
- Use `MockLLMProvider` (in `AriaTesting`) for agent tests.
- Use `HashEmbedder` (in `AriaTesting`) for embedder tests.
- Tests should be deterministic. No real network calls, no real model inference, no time-dependent assertions without explicit clocks.

## Commits and PRs

- Commit messages: imperative mood, present tense. "Add Runnable.pipe" not "Added" or "Adds".
- One logical change per commit. Squashing OK for small fix-ups.
- PR descriptions reference relevant docs (e.g., "implements Layer 2 per `docs/layers/02-runnable.md`").
- Keep PRs focused. A 200-line PR gets reviewed; a 2000-line PR gets rubber-stamped.

## What to do when ambiguity strikes

1. Check `docs/principles.md` and `docs/decisions/`.
2. Check the relevant layer doc in `docs/layers/`.
3. Look for a similar pattern already in the codebase.
4. If still ambiguous, leave a comment with `TODO(architecture):` and ask in the PR.

Do not invent new abstractions speculatively. Add abstractions when the second concrete use case appears.

## What to never do

- Copy code from another framework. (See independence statement above.)
- Add Apple imports to `Aria`.
- Introduce singletons, globals, or service locators.
- Add `[String: Any]` to public APIs except as user-supplied metadata.
- Add features for hypothetical future requirements.
- Skip writing tests for new public APIs.
- Reformat unrelated code in a feature PR.
- Use `try!` or `as!` outside of test code.
- Use `print(...)` for logging (use `Logger`).

## When using AI assistance

If you are an AI coding assistant working on this repo:

- Read this file and `docs/principles.md` before making changes.
- Do not introduce dependencies without explicit human approval.
- When uncertain about whether an API or pattern would constitute "lifting IP" from another framework, refuse and ask. Do not produce code based on memorized snippets from third-party frameworks.
- When citing an inspiration in code comments, cite a paper or a textbook concept (e.g., "// ReAct pattern, Yao et al. 2022"), not a specific framework's source file.
- Prefer adding to `docs/` when the change touches architecture; the docs are the source of truth.
