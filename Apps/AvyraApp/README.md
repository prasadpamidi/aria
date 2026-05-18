# Avyra — SwiftUI iOS App

A SwiftUI iOS app that consumes the Aria Swift Package as a local dependency. Avyra is the user-facing app; **Aria** is the library that powers it.

## Layout

```
Apps/AvyraApp/
├── Avyra.xcodeproj/           Xcode project
├── Avyra/                     App target sources, organized by surface
│   ├── App/                   Entry point, root nav, global app state
│   │   ├── AvyraApp.swift
│   │   ├── RootTabView.swift
│   │   ├── AppState.swift
│   │   └── Item.swift         SwiftData scaffolding (template)
│   ├── Chat/                  Main chat surface + its widgets
│   │   ├── ChatScreen.swift
│   │   ├── MessageBubble.swift
│   │   ├── MessageContentParser.swift
│   │   ├── TypingIndicator.swift
│   │   ├── QuickActionChips.swift
│   │   ├── ModelStatusPill.swift
│   │   ├── SmoothTextStreamer.swift
│   │   ├── TranscriptInbox.swift
│   │   ├── AssistantError.swift
│   │   └── ErrorCard.swift
│   ├── Models/                In-chat model picker
│   │   └── ModelPickerSheet.swift
│   ├── Settings/              Settings sheet + screens reached from it
│   │   ├── AvyraSettings.swift
│   │   ├── SettingsScreen.swift
│   │   ├── MemoriesScreen.swift
│   │   └── PreviousChatsScreen.swift
│   ├── Demos/                 Developer-mode demo surfaces
│   │   ├── DemosScreen.swift
│   │   ├── HaikuChain.swift
│   │   ├── HaikuChainScreen.swift
│   │   ├── SuggestActivityScreen.swift
│   │   └── ActivitySuggestion.swift
│   ├── Shared/                Cross-cutting helpers + agent tools
│   │   ├── RememberTool.swift
│   │   ├── CurrentTimeTool.swift
│   │   ├── ImageDownsampler.swift
│   │   └── ShareSheet.swift
│   ├── AvyraApp.entitlements
│   └── Assets.xcassets/
├── AvyaTests/                 Unit tests (Swift Testing)
└── AvyraUITests/              UI tests (XCTest)
```

Folder grouping is purely organizational — the Xcode project uses `fileSystemSynchronizedGroups`, so source files are auto-discovered by the build target regardless of nesting.

## Package wiring

The Xcode project references the Aria Swift Package as a **local** dependency at `../../..` (the repo root). Targets:

| Target | Linked products |
|---|---|
| `Avyra` (app) | `Aria`, `AriaApple`, `AriaMLX` |
| `AvyraTests` | `Aria`, `AriaTesting` |
| `AvyraUITests` | (none — UI tests don't import Aria) |

When you change the package, Xcode rebuilds affected products on next build. No "Update Packages" step needed for local refs.

## Running

```bash
# Open in Xcode
open Apps/AvyraApp/Avyra.xcodeproj

# Or build from CLI
xcodebuild build \
  -project Apps/AvyraApp/Avyra.xcodeproj \
  -scheme Avyra \
  -destination 'platform=iOS Simulator,name=iPhone 17'

# Or via Fastlane
bundle exec fastlane sample_build
```

## Deployment target

The project targets iOS 26.4. Aria itself requires iOS 17+ at the package level; Avyra sets a higher minimum to use FoundationModels (iOS 26+) via `AriaApple.FoundationModelsProvider`.

## Bundle identifiers

- App: `com.3theories.app.Avyra`
- Tests: `com.3theories.app.Avyra.Tests`
- UI tests: `com.3theories.app.Avyra.UITests`

Change these in the project's Signing & Capabilities pane if publishing under a different team or bundle prefix.

## Naming convention

- **Aria** — the library / Swift package
- **Avyra** — the app that uses the library

In code: `import Aria`, `import AriaApple`, `import AriaMLX` (library imports stay as-is). App-internal types use the `Avyra` prefix (`AvyraApp`, `AvyraSettings`, `AvyraConstants`).
