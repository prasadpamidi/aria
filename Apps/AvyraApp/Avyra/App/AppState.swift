import Aria
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
    // MARK: Lifecycle

    init() { }

    // MARK: Internal

    #if canImport(AriaMLX)
        /// The SDK-provided manager that bundles model store +
        /// downloader + disk manager + active-model selection.
        /// Drive the chat agent through `manager.makeProvider()`;
        /// drive Avyra's `ModelPickerSheet` (in-app catalog +
        /// download UI) against it.
        ///
        /// `persistenceKey` makes the manager mirror the active
        /// model into `UserDefaults`, so the next launch restores
        /// the user's last pick (and silently falls back to
        /// FoundationModels if the model has been removed from
        /// disk since).
        let modelManager = MLXModelManager(
            persistenceKey: "aria.sample.mlx.activeModelID"
        )
    #endif

    /// App-scoped owner of model download tasks. Centralized here so
    /// a download survives the user navigating off the family detail
    /// screen, and so the "keep the app open" banner can observe
    /// whether any download is in flight from anywhere in the app.
    let downloads = DownloadCoordinator()

    /// In-memory chat history used when persistence is turned off in
    /// Settings → Privacy. Lives for the lifetime of the app launch
    /// so the active conversation still has cross-turn context within
    /// the session — only the GRDB write is skipped. Pre-existing
    /// threads in `storage.chatHistory` remain readable via Previous
    /// chats regardless of this flag.
    let ephemeralHistory = InMemoryChatHistory()
}
