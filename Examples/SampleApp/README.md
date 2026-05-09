# AriaSample — SwiftUI Sample App

A SwiftUI iOS app that consumes the Aria Swift Package as a local dependency. This is the place to build and test Aria features end-to-end while implementation lands.

## Layout

```
Examples/SampleApp/
├── AriaSample.xcodeproj/      Xcode project
├── AriaSample/                App target sources
│   ├── AriaSampleApp.swift    Entry point
│   ├── ContentView.swift      Aria demo view
│   ├── Item.swift             SwiftData scaffolding (template-generated)
│   └── Assets.xcassets/
├── AriaSampleTests/           Unit tests (Swift Testing)
└── AriaSampleUITests/         UI tests (XCTest)
```

## Package wiring

The Xcode project references the Aria Swift Package as a **local** dependency at `../..` (the repo root). Targets:

| Target | Linked products |
|---|---|
| `AriaSample` (app) | `Aria`, `AriaApple` |
| `AriaSampleTests` | `Aria`, `AriaTesting` |
| `AriaSampleUITests` | (none — UI tests don't import Aria) |

When you make changes to the package, Xcode rebuilds the affected products on next build. No "Update Packages" step needed for local refs.

## Running

```bash
# Open in Xcode
open Examples/SampleApp/AriaSample.xcodeproj

# Or build from CLI
xcodebuild build \
  -project Examples/SampleApp/AriaSample.xcodeproj \
  -scheme AriaSample \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

## Deployment target

The project targets iOS 26.4. Aria requires iOS 17+ at the package level; the sample app sets a higher minimum to use FoundationModels (iOS 26+) once `AriaApple.FoundationModelsProvider` lands.

## Bundle identifiers

- App: `com.3theories.AriaSample`
- Tests: `com.3theories.AriaSampleTests`
- UI tests: `com.3theories.AriaSampleUITests`

Change these in the project settings if you publish under a different team or bundle prefix.
