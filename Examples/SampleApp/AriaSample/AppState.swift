import Foundation
import Observation

#if canImport(AriaMLX)
    import AriaMLX
#endif

// MARK: - AppState

/// Shared, MainActor-isolated state the chat UI threads between
/// menus, sheets, and the agent factory.
///
/// Centralized here (instead of scattered `@State` in `ContentView`)
/// because the model store has to outlive any single sheet — the
/// store caches loaded `ModelContainer`s and re-loading them on every
/// sheet dismiss would defeat the cache.
@MainActor
@Observable
final class AppState {
    /// HF id of the MLX model the chat agent should drive. `nil`
    /// means "use FoundationModels" (the default before any model
    /// is downloaded).
    var selectedMLXModelID: String?

    #if canImport(AriaMLX)
        /// Long-lived `ModelContainer` cache. Held here so a single
        /// download survives across menu re-opens and is shared
        /// between the Models sheet and the chat agent.
        let mlxStore = MLXModelStore()
    #endif

    init() {}
}
