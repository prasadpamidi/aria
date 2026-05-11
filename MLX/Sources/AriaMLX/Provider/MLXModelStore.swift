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

        /// - Parameter evictOnLoad: when `true` (the default), loading
        ///   a new model id evicts every other cached container before
        ///   the load starts. On-device, MLX weights are big — Gemma 4
        ///   e2b plus Qwen 2.5 VL resident at the same time is enough
        ///   to get iOS to jetsam the app — so the single-slot policy
        ///   matches the "one active model per conversation" UX. Set
        ///   to `false` on hosts with plenty of RAM that want
        ///   instant switching between cached models.
        public init(
            downloader: MLXModelDownloader = MLXModelDownloader(),
            evictOnLoad: Bool = true
        ) {
            self.downloader = downloader
            self.evictOnLoad = evictOnLoad
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
            toolCallFormat: ToolCallFormat? = nil,
            onProgress: @Sendable @escaping (MLXDownloadProgress) -> Void = { _ in }
        ) async throws -> ModelContainer {
            if let existing = self.cached[id] {
                return existing
            }
            if let inFlight = self.inFlight[id] {
                return try await inFlight.value
            }
            if self.evictOnLoad {
                self.evictOthers(keeping: id)
            }
            let task = Task {
                try await self.downloader.loadContainer(
                    id: id,
                    kind: kind,
                    revision: revision,
                    useLatest: false,
                    toolCallFormat: toolCallFormat,
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
        private let evictOnLoad: Bool
        private var cached: [String: ModelContainer] = [:]
        private var inFlight: [String: Task<ModelContainer, any Error>] = [:]

        /// Drop every cached container except `id`. Swift's ARC then
        /// runs each `ModelContainer`'s deinit, which releases the
        /// MLX weight tensors back to the system.
        private func evictOthers(keeping id: String) {
            for cachedId in self.cached.keys where cachedId != id {
                self.cached[cachedId] = nil
            }
        }
    }
#endif
