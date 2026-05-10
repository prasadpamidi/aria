#if canImport(MLXLMCommon)
    import Foundation
    import MLXLMCommon
    import Observation

    // MARK: - MLXModelManager

    /// One-stop facade for picking, downloading, and selecting an
    /// active MLX model.
    ///
    /// Wraps the lower-level pieces (`MLXModelStore`,
    /// `MLXModelDownloader`, `MLXModelDiskManager`) and adds the
    /// "currently active" selection state so apps can bind it
    /// directly to UI. The lower-level types stay public, so apps
    /// that need full control can use them directly without going
    /// through the manager.
    ///
    /// Two ways to consume:
    ///
    /// 1. **Headless** — instantiate `MLXModelManager`, call
    ///    `setActiveModel(id:)` after `download(...)` succeeds, then
    ///    use `makeProvider()` each turn when configuring an Agent.
    /// 2. **With provided UI** — pass the manager to
    ///    `MLXModelsView` (in `AriaMLX`) and let users browse,
    ///    download, select, and delete models with no extra code.
    ///
    /// `@Observable` so SwiftUI rerenders when the active model or
    /// downloaded list changes.
    @MainActor
    @Observable
    public final class MLXModelManager {
        // MARK: Lifecycle

        public init(
            catalog: [MLXModelCapabilities] = MLXModelCatalog.defaults,
            store: MLXModelStore = MLXModelStore(),
            downloader: MLXModelDownloader = MLXModelDownloader(),
            diskManager: MLXModelDiskManager = MLXModelDiskManager()
        ) {
            self.catalog = catalog
            self.store = store
            self.downloader = downloader
            self.diskManager = diskManager
        }

        // MARK: Public

        /// Models the manager surfaces in the catalog UI. Mutable so
        /// apps can extend the curated defaults at runtime (e.g. add
        /// a model fetched from a remote config).
        public var catalog: [MLXModelCapabilities]

        /// HF id of the currently-active model. `nil` means no MLX
        /// model is active — the agent should fall back to a
        /// non-MLX provider (FoundationModels, etc).
        public var activeModelID: String?

        public let store: MLXModelStore
        public let downloader: MLXModelDownloader
        public let diskManager: MLXModelDiskManager

        /// The active model's capabilities, looked up in the
        /// catalog. `nil` when nothing is selected or the id isn't
        /// in the catalog.
        public var activeCapabilities: MLXModelCapabilities? {
            guard let id = self.activeModelID else {
                return nil
            }
            return self.catalog.first { $0.id == id }
        }

        /// Look up a catalog entry by id.
        public func entry(for id: String) -> MLXModelCapabilities? {
            self.catalog.first { $0.id == id }
        }

        /// Activate `id` so the next `makeProvider()` call returns
        /// an `MLXProvider` bound to it. Setting to `nil` clears the
        /// selection. No download is triggered — call
        /// `download(id:)` first (or use the provided UI) to ensure
        /// weights are on disk.
        public func setActiveModel(id: String?) {
            self.activeModelID = id
        }

        /// Build an `MLXProvider` for the active model.
        ///
        /// Returns `nil` when no MLX model is selected; consumers
        /// should fall through to whatever non-MLX provider they
        /// configure (e.g. `FoundationModelsProvider`). Cheap to
        /// call — providers are value types holding references to
        /// the shared store.
        public func makeProvider(
            defaultInstructions: String? = nil,
            generationParameters: GenerateParameters = GenerateParameters()
        ) -> MLXProvider? {
            guard let capabilities = self.activeCapabilities else {
                return nil
            }
            return MLXProvider(
                capabilities: capabilities,
                store: self.store,
                defaultInstructions: defaultInstructions,
                generationParameters: generationParameters
            )
        }

        /// Stream download progress for `id`. Drives any UI binding
        /// directly — no extra plumbing needed. Cancellation
        /// propagates to the underlying downloader.
        public func downloadProgress(
            for id: String,
            revision: String = "main",
            useLatest: Bool = false
        ) -> AsyncThrowingStream<MLXDownloadProgress, any Error> {
            let kind = self.entry(for: id)?.kind ?? .textOnly
            return self.downloader.progressStream(
                id: id,
                kind: kind,
                revision: revision,
                useLatest: useLatest
            )
        }

        /// One-shot download convenience — awaits the container
        /// without surfacing progress. Use `downloadProgress(for:)`
        /// when the UI needs a progress bar.
        public func download(
            id: String,
            revision: String = "main",
            useLatest: Bool = false
        ) async throws {
            let kind = self.entry(for: id)?.kind ?? .textOnly
            _ = try await self.downloader.loadContainer(
                id: id,
                kind: kind,
                revision: revision,
                useLatest: useLatest
            )
        }

        /// List every model the disk manager finds in the cache
        /// root, regardless of catalog membership. Useful for an
        /// "all downloaded models" inspector view.
        public func downloadedModels() throws -> [MLXDiskModel] {
            try self.diskManager.list()
        }

        /// Whether `id` has been downloaded.
        public func isDownloaded(id: String) throws -> Bool {
            try self.diskManager.find(id: id) != nil
        }

        /// Remove a downloaded model from disk and unload its
        /// container from the store. If `id` is the active model,
        /// the selection is cleared so the next agent run falls
        /// through to the non-MLX provider.
        public func remove(id: String) async throws {
            try self.diskManager.remove(id: id)
            await self.store.unload(id: id)
            if self.activeModelID == id {
                self.activeModelID = nil
            }
        }
    }

#endif
