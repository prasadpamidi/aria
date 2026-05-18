# CLAUDE.md — Claude Code Notes for Aria

This file is for Claude Code specifically. The primary AI guidance lives in [AGENTS.md](AGENTS.md). Read that first.

## Quick orientation

- **Project:** Aria — composable on-device agent runtime for Apple platforms.
- **Status:** Architecture and design phase. Implementation has not yet begun.
- **Source of truth:** `docs/`. The protocols and types described in `docs/layers/` are the target architecture.
- **Independence:** This is a clean-room project. **Do not copy code or documentation from other frameworks, like LangChain.js, LangGraph.js, or any other framework.** See [NOTICE.md](NOTICE.md).

## One-time setup

```bash
brew bundle                   # swiftformat, swiftlint
bundle install                # fastlane
./scripts/install-hooks.sh    # pre-commit hook
```

## Common commands

**Use Fastlane for everything.** Local development and CI run the
same lanes — if it passes here, it passes there. Don't reach for
`swift build`, `swift test`, or `xcodebuild` directly; pick a lane.

```bash
# Package (Aria core + AriaApple + AriaTesting + AriaTools)
bundle exec fastlane package_build       # build all targets
bundle exec fastlane package_tests       # all tests
bundle exec fastlane core_tests          # core tests only (Linux-safe)
bundle exec fastlane cli_demo            # run the CLI demo

# App (Avyra, the iOS app on top of Aria)
bundle exec fastlane app_local_build                                  # build for iOS Simulator
bundle exec fastlane app_local_build device:'iPhone 17 Pro' clean:true # named device + clean
bundle exec fastlane app_tests                                        # run Avyra tests on Simulator

# Code quality
bundle exec fastlane lint                # SwiftLint
bundle exec fastlane format              # SwiftFormat (in place)
bundle exec fastlane quality             # format --lint + lint
bundle exec fastlane quality fix:true    # both, auto-fix
```

Only direct invocation that's normal: opening the project in Xcode.

```bash
open Apps/AvyraApp/Avyra.xcodeproj
```

Anything else that wants to bypass Fastlane probably means a missing
lane — add one in `fastlane/Fastfile` rather than running raw
`swift`/`xcodebuild`. The only current gap is the `MLX/` sub-package
(its own `Package.swift`); CI handles that with `cd MLX && swift
build && swift test`.

See `AGENTS.md` for the full lane reference.

## When working in this repo

1. **Before adding code:** check `docs/architecture.md` and the relevant `docs/layers/*.md`.
2. **Before introducing an abstraction:** confirm there are at least two concrete use cases.
3. **Before importing anything:** confirm `Aria` only imports from the allowed list in `docs/platform-boundary.md`.
4. **Before claiming a feature is complete:** verify on Linux (`swift build --target Aria` in a Linux container or via CI).

## Things Claude Code should not do

- Run `xcodebuild`, `swift build`, `swift test`, or `swift run`
  directly. Use the matching Fastlane lane every time. Only fall
  back to a raw invocation when the user explicitly asks or there
  is genuinely no lane (today: just the `MLX/` sub-package).
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
