# ADR 0002 — Platform-agnostic core, Linux-buildable

**Status:** Accepted
**Date:** 2026-05-09

## Context

Aria is iOS-first. The immediate target is iPhone, iPad, Mac, and other Apple platforms. There is, however, a credible long-term scenario in which agent logic shipped today on iOS may need to run on Android, on a server, or in some other Swift-capable environment.

The question: do we design the core as Apple-platform-native (using `OSLog`, `Combine`, `FoundationModels`, `URLSession` directly), or do we discipline ourselves to keep the core platform-agnostic and put platform-specific code in a separate target?

## Decision

The `Aria` target is platform-agnostic. It compiles, links, and tests on Linux. All Apple-platform-specific code lives in `AriaApple`.

## Rationale

1. **Mechanical enforcement of cleanliness.** A Linux build job in CI catches every accidental Apple import. Discipline becomes a compiler-checked invariant rather than a code-review aspiration.

2. **Future portability is preserved at near-zero cost.** Swift on Linux, Skip, the Swift Android workgroup, KMP wrappers — multiple paths to non-Apple platforms exist. None require us to do anything different in core today; the discipline is the cost of admission.

3. **Faster CI.** Linux runners are cheaper and faster than macOS runners. Most unit tests run on Linux.

4. **Better module boundaries.** Forcing the question "could this be a protocol with a default impl in core?" produces better designs than "let me just import OSLog."

5. **Swift's standard library and Foundation subset are sufficient.** We don't need much: `Codable`, `Data`, `URL`, `Date`, Swift Concurrency, `Logger` from swift-log. The Apple-specific shine (`OSLog`, `Combine`, `FoundationModels`) is for the platform module.

## Consequences

### Positive

- Cross-platform potential without a rewrite.
- Fast unit-test loop on Linux.
- Cleaner module structure.
- The core is forced to define swap points (HTTP client, storage, logging) rather than embedding implementations.

### Negative

- Marginally more boilerplate at the platform module to wire up Apple-specific implementations of core protocols.
- Some Apple ergonomic features (e.g., `os_log` formatting macros) cannot be used in core.
- The team must internalize the rule list in `docs/platform-boundary.md`.

### Mitigations

- The platform-boundary document is short, clear, and CI-enforced.
- The Apple module ships sensible defaults (e.g., `URLSession`-backed `HTTPClient`, `OSLog`-backed log handler) so consumers do not feel the wiring overhead.
- A simple "is this Apple-only?" review checklist for PRs that touch core.

## Alternatives considered

### A. Apple-platform-native core, with future "we'll fix it when we port" intent
Rejected. Every platform-port project that adopted this strategy has paid an enormous tax later. The time to keep options open is now, while the codebase is small.

### B. `#if os(...)` guards inside the core
Rejected. Conditional compilation defers the discipline and makes core behavior depend on the build target. It also defeats the Linux CI guard. Physical separation (`AriaApple` is a separate module) is the better pattern.

### C. Build for iOS only, ignore portability entirely
Rejected because cross-platform is a stated goal of the project, even if not on the immediate roadmap.

## Implementation notes

See `docs/platform-boundary.md` for the full rule set:

- What's allowed in core (Swift stdlib, Foundation subset, Swift Concurrency, swift-log, swift-collections).
- What's banned in core (UIKit, AppKit, SwiftUI, FoundationModels, OSLog, Combine, EventKit, MLX, etc.).
- CI enforcement via Linux build jobs.
- Common leak patterns to watch for.

## Revisiting

This decision should be revisited if:

- A genuinely necessary Apple-only capability cannot be expressed via a protocol + platform impl.
- Linux CI proves too costly or unreliable.
- A formal cross-platform strategy emerges that prefers a different boundary (e.g., KMP-shaped).
