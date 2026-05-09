# CLAUDE.md — Claude Code Notes for Aria

This file is for Claude Code specifically. The primary AI guidance lives in [AGENTS.md](AGENTS.md). Read that first.

## Quick orientation

- **Project:** Aria — composable on-device agent runtime for Apple platforms.
- **Status:** Architecture and design phase. Implementation has not yet begun.
- **Source of truth:** `docs/`. The protocols and types described in `docs/layers/` are the target architecture.
- **Independence:** This is a clean-room project. **Do not copy code or documentation from LangChain.js, LangGraph.js, or any other framework.** See [NOTICE.md](NOTICE.md).

## One-time setup

```bash
brew bundle                   # swiftformat, swiftlint
bundle install                # fastlane
./scripts/install-hooks.sh    # pre-commit hook
```

## Common commands

```bash
# Package
swift build                              # build all targets
swift test                               # all tests
swift test --filter AriaTests            # core tests (Linux-safe)
swift run AriaCLI                        # CLI demo

# Fastlane (preferred)
bundle exec fastlane package_tests       # swift test wrapped
bundle exec fastlane core_tests          # core tests only
bundle exec fastlane sample_build        # build AriaSample on iOS Simulator
bundle exec fastlane lint                # SwiftLint
bundle exec fastlane format              # SwiftFormat
bundle exec fastlane quality             # both, lint mode
bundle exec fastlane quality fix:true    # both, auto-fix

# AriaSample directly
open Examples/SampleApp/AriaSample.xcodeproj
```

See `AGENTS.md` for the full lane reference.

## When working in this repo

1. **Before adding code:** check `docs/architecture.md` and the relevant `docs/layers/*.md`.
2. **Before introducing an abstraction:** confirm there are at least two concrete use cases.
3. **Before importing anything:** confirm `Aria` only imports from the allowed list in `docs/platform-boundary.md`.
4. **Before claiming a feature is complete:** verify on Linux (`swift build --target Aria` in a Linux container or via CI).

## Things Claude Code should not do

- Run `xcodebuild` proactively. Only run it when the user asks.
- Add Apple imports to the `Aria` target.
- Introduce dependencies without asking.
- Create stub implementations for unrelated layers when working on one layer.
- Generate code that resembles, in shape or naming, code from a known third-party framework. If a snippet "feels" like it's from LangChain — do not produce it; ask instead.

## Things Claude Code should do

- Treat `docs/` as the spec. If implementation diverges from docs, update one of them.
- Write tests alongside new public APIs.
- Use `swift-log` for logging in core; `OSLog` is fine in `AriaApple`.
- Prefer `some Runnable<I, O>` opaque types over `AnyRunnable` at API boundaries.
- Run `swift build --target Aria` mentally (or actually) before committing — confirm the platform boundary holds.

## Useful pointers

- Architecture overview: `docs/architecture.md`
- Principles: `docs/principles.md`
- Platform rules: `docs/platform-boundary.md`
- Decision log: `docs/decisions/`
- Glossary: `docs/glossary.md`
