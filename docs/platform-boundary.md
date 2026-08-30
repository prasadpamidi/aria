# Platform Boundary

The single most important architectural rule in Aria is the **platform boundary** between the core target (`Aria`) and the Apple-platform target (`AriaApple`). This document is the full rule set for that boundary.

## The rule

> The `Aria` target compiles, links, and runs its unit tests on Linux.

Every other rule in this document follows from that one. If a change breaks the Linux build, the change is wrong.

## What the rule buys

1. **Mechanical enforcement of cross-platform potential.** No discipline required; the compiler catches violations.
2. **Fast CI.** Linux containers are cheaper and faster than macOS runners. Most unit tests run on Linux.
3. **Clean module boundaries.** It becomes impossible to leak Apple types into the core inadvertently.
4. **Future portability.** When the time comes to support Android (via Skip, KMP wrapper, or Swift Android toolchain), the porting surface is small and well-defined.

## What is allowed in `Aria`

Pure Swift and a curated subset of Foundation that exists on swift-corelibs.

- Swift Standard Library (`Array`, `Dictionary`, `Optional`, `Result`, etc.)
- Swift Concurrency (`Task`, `actor`, `AsyncSequence`, `AsyncStream`, `AsyncThrowingStream`, `Sendable`, `withTaskGroup`)
- `Codable`, `Encoder`, `Decoder`, `JSONEncoder`, `JSONDecoder`
- `Data`, `URL`, `UUID`, `Date`, `TimeInterval`, `ContinuousClock`
- `Logger` from `swift-log` (for logging)
- `swift-collections` (for ordered collections, deque, etc.)
- Swift's native `Regex` (Swift 5.7+)

## What is banned in `Aria`

Apple-only or Darwin-only frameworks. The compiler will catch most of these on Linux automatically; this list is for human review.

- `import UIKit`, `import AppKit`, `import SwiftUI`, `import WatchKit`
- `import FoundationModels`, `import CoreML`, `import CreateML`, `import NaturalLanguage`
- `import Combine` (use `AsyncSequence`)
- `import OSLog`, `os_log` (use `swift-log`)
- `import EventKit`, `import HealthKit`, `import Contacts`, `import CoreLocation`
- `import AVFoundation`, `import Photos`
- `import MLX`, `import MLXNN` (Apple-platform MLX bindings)
- `@Generable` macro and other FoundationModels macros
- `URLSession` directly (use a protocol; Apple impl wraps URLSession)
- `NSRegularExpression` (use Swift `Regex`)
- `DispatchQueue` (use Swift Concurrency)

## What is allowed conditionally

A small number of Foundation APIs work on Linux but have semantic differences. Use them carefully and prefer protocols when possible.

- `FileManager`: works on Linux but file-system semantics differ. Prefer injecting a `Storage` protocol.
- `URLSession` *as a type*: exists on Linux via swift-corelibs, but performance and behavior differ. Aria uses an `HTTPClient` protocol; the Linux build may stub it.
- `ProcessInfo`, `Bundle`: work on Linux but with limited functionality. Avoid in core.

## Logging

Aria uses [`swift-log`](https://github.com/apple/swift-log) for logging. The core target depends on `Logging` and emits logs through it. The platform module installs a backend at startup:

- On Apple platforms, `AriaApple` installs an `OSLog`-backed log handler.
- On Linux, the default `swift-log` console handler is used.
- Consumers can install their own handler.

Direct `OSLog` or `os_log` use is forbidden in `Aria`.

## HTTP

Aria does not perform HTTP from the core target. Components that need HTTP (e.g., a remote tool) take an `HTTPClient` protocol via dependency injection:

```swift
public protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
    func stream(_ request: HTTPRequest) -> AsyncThrowingStream<Data, Error>
}
```

The Apple module provides a `URLSession`-backed implementation. Other platforms provide their own.

## Storage

Same pattern as HTTP. The core defines protocols (`ChatHistory`, `Checkpointer`, `VectorStore`); platforms provide implementations. The core ships in-memory defaults that work everywhere.

## Conditional compilation

Aria uses `#if canImport(...)` sparingly. The preferred pattern is **physical separation**: Apple-only code lives in `AriaApple`, not in `Aria` behind `#if`.

If conditional compilation is unavoidable in core (very rare), use `#if canImport(...)` rather than `#if os(...)`. Reason: `canImport` is robust to future platforms; `os` requires updating every time a new target appears.

## Apple model adapters

Foundation Models adapters belong in `AriaApple`. The portable `LLMProvider`
surface in `Aria` must not expose `LanguageModel`, `LanguageModelSession`, or
other Apple framework types.

An application may inject an iOS 27 `LanguageModel` into
`FoundationModelsProvider`, including one supplied by Core AI. The application
owns that runtime dependency and its model resources. Neither the root package
graph nor `AriaApple` should add a direct Core AI dependency: integration occurs
through the Foundation Models protocol, keeping Core AI optional and leaving
device eligibility and fallback decisions with the application.

## CI enforcement

Aria's CI matrix:

| Job | Runs on | What it builds |
|---|---|---|
| `aria-linux` | Linux container (e.g., Swift official Docker image) | `swift build --target Aria`, `swift test --target AriaTests` |
| `aria-macos` | macOS runner | `swift build`, `swift test` (all targets) |
| `aria-ios` | macOS runner | `xcodebuild -scheme Aria-iOS` (smoke build) |

The `aria-linux` job is required for merge. If it fails, the platform boundary has been violated.

## Common leaks to watch for

These are the "easy mistakes" that experienced Apple developers make when writing core code:

| Leak | Replacement |
|---|---|
| `OSLog`, `os_log` | `swift-log` `Logger` |
| `JSONEncoder().outputFormatting = .sortedKeys` | Fine, cross-platform — *not actually a leak*, included to clarify |
| `URLSession.shared` | `HTTPClient` protocol |
| `DispatchQueue.global().async` | `Task { ... }` |
| `Notification.Name`, `NotificationCenter` | `AsyncStream` |
| `NSError`, bridging | `enum AgentError: Error` |
| `NSRegularExpression` | Swift `Regex` |
| `KeyPath<Root, Value>` exposing `NSObject` | Swift native key paths only |
| `Combine.Publisher` | `AsyncSequence` |
| `@MainActor` *in protocols* | Don't bake UI threading into core protocols. Apple consumers can wrap |
| `import UIKit` for `UIImage` in tool I/O | Use `Data` + a content-type tag |

## Reviewing PRs against this rule

When reviewing a change to `Aria`:

1. Did the diff add an `import` statement? If yes, is the import in the allowed list?
2. Does the change call any function with `NS` or `CG` prefix? Probably a leak.
3. Does the change use `OSLog`, `Combine`, or `DispatchQueue`? Definitely a leak.
4. Could the same functionality be expressed via a protocol with the platform-specific impl in `AriaApple`? If yes, do that.

## Why not just use `#if os(iOS)` everywhere?

- It defers the discipline. The code drifts toward Apple-only over time.
- It makes the core target's behavior depend on the build target — confusing and hard to test.
- It defeats the Linux CI guard.
- When porting to a new platform, every `#if os(iOS)` becomes a question to answer.

Physical separation is the harder discipline upfront, but it pays back every day after.
