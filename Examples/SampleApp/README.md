# Aria Sample App

A starter SwiftUI app demonstrating Aria's intended API.

> **Note:** Aria is in architecture & design phase. This sample is a template; the API references here describe the *target* shape and will compile once core implementation lands.

## Setup

1. **Create a new Xcode project**: File → New → Project → iOS → App. Choose SwiftUI as the interface.
2. **Set deployment target** to iOS 17 or later.
3. **Add Aria as a local Swift Package dependency**:
   - File → Add Package Dependencies… → Add Local…
   - Select the root `aria/` directory of this repository.
   - Add the `Aria`, `AriaApple`, and `AriaTools` library products to your app target.
4. **Replace `ContentView.swift`** in your new project with the file in this folder.
5. **Build and run** on an iOS 26+ simulator (FoundationModels availability) once `AriaApple` implementations exist.

## Files

- [`ContentView.swift`](ContentView.swift) — SwiftUI view demonstrating Aria's intended API. Uses placeholders where implementations are pending.

## What this demonstrates (target API)

Once core implementation is complete, this sample will show:

- Constructing an `Agent` with `FoundationModelsProvider` and a tool set
- Streaming `AgentEvent`s into SwiftUI state
- Tool-call status badges in the UI
- Persistent conversation history via `SwiftDataChatHistory`
- Per-thread checkpointing via `SwiftDataCheckpointer`

## Why this isn't an Xcode project today

A standalone Xcode project (`.xcodeproj` / `.xcworkspace`) is best created in Xcode itself; checking one in alongside the package adds noise and friction. The setup steps above are quick, and the resulting project is yours to evolve.

If a checked-in sample app becomes valuable later (e.g., for screen recordings, App Store submission, or CI smoke runs), one can be added at that point.
