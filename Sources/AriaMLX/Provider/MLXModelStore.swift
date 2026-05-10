#if canImport(MLXLMCommon)
    import Foundation
    import MLXLMCommon

    // MARK: - MLXModelStore

    /// Caches loaded `ModelContainer`s keyed by Hugging Face id so the
    /// provider can switch between models cheaply (one download per id;
    /// subsequent calls reuse the in-memory container).
    ///
    /// Loading is `actor`-isolated so two concurrent agent runs trying
    /// to load the same model serialize cleanly. Each cache entry is
    /// refcount-light: `unload(id:)` drops the container; the next
    /// `container(for:)` re-loads.
    public actor MLXModelStore {
        // MARK: Lifecycle

        public init(downloader: MLXModelDownloader = MLXModelDownloader()) {
            self.downloader = downloader
        }

        // MARK: Public

        /// Return the loaded container for `id`, downloading + loading
        /// it on first access. Concurrent calls for the same id
        /// coalesce: the first caller drives the load; subsequent ones
        /// await the same task.
        public func container(
            for id: String,
            kind: MLXModelKind = .textOnly,
            revision: String = "main",
            onProgress: @Sendable @escaping (MLXDownloadProgress) -> Void = { _ in }
        ) async throws -> ModelContainer {
            if let existing = self.cached[id] {
                return existing
            }
            if let inFlight = self.inFlight[id] {
                return try await inFlight.value
            }
            let task = Task {
                try await self.downloader.loadContainer(
                    id: id,
                    kind: kind,
                    revision: revision,
                    useLatest: false,
                    onProgress: onProgress
                )
            }
            self.inFlight[id] = task
            do {
                let container = try await task.value
                self.cached[id] = container
                self.inFlight[id] = nil
                return container
            } catch {
                self.inFlight[id] = nil
                throw error
            }
        }

        /// Drop the cached container for `id`. The model files stay on
        /// disk; only the in-memory weights are released. Useful when
        /// switching models on a memory-constrained device.
        public func unload(id: String) {
            self.cached[id] = nil
        }

        /// Drop every cached container. Models stay on disk.
        public func unloadAll() {
            self.cached.removeAll()
        }

        // MARK: Private

        private let downloader: MLXModelDownloader
        private var cached: [String: ModelContainer] = [:]
        private var inFlight: [String: Task<ModelContainer, any Error>] = [:]
    }
#endif
