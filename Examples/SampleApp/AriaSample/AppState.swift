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
/// because the model manager has to outlive any single sheet — its
/// `MLXModelStore` caches loaded `ModelContainer`s and re-loading
/// them on every sheet dismiss would defeat the cache.
@MainActor
@Observable
final class AppState {
    #if canImport(AriaMLX)
        /// The SDK-provided manager that bundles model store +
        /// downloader + disk manager + active-model selection.
        /// Drive the chat agent through `manager.makeProvider()`
        /// and present the SDK's `MLXModelsView` against it.
        let modelManager = MLXModelManager()
    #endif

    init() {}
}
