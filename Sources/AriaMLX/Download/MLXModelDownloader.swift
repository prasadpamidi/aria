#if canImport(MLXLMCommon)
    import Foundation
    import HuggingFace
    import MLXLMCommon
    import MLXLMHuggingFace
    import MLXLMTransformers

    // MARK: - MLXDownloadProgress

    /// One progress tick emitted while a model is being fetched.
    public struct MLXDownloadProgress: Sendable, Hashable {
        // MARK: Lifecycle

        public init(completed: Int64, total: Int64?, fraction: Double?) {
            self.completed = completed
            self.total = total
            self.fraction = fraction
        }

        init(progress: Progress) {
            self.completed = progress.completedUnitCount
            let total = progress.totalUnitCount
            if total > 0 {
                self.total = total
                self.fraction = progress.fractionCompleted
            } else {
                self.total = nil
                self.fraction = nil
            }
        }

        // MARK: Public

        /// Bytes already on disk.
        public let completed: Int64
        /// Total bytes to download. May be `nil` early in the snapshot.
        public let total: Int64?
        /// `0.0…1.0`, or `nil` when total is unknown.
        public let fraction: Double?
    }

    // MARK: - MLXModelDownloader

    /// Wraps `MLXLMTransformers.loadModelContainer` (which depends on
    /// `swift-huggingface`'s `HubClient` for the actual file fetch) into
    /// an `AsyncStream` of `MLXDownloadProgress` so SwiftUI can render
    /// progress directly. Also exposes a `containerStream` for callers
    /// that want both progress and the produced `ModelContainer`.
    public struct MLXModelDownloader: Sendable {
        // MARK: Lifecycle

        public init(hubClient: HubClient = HubClient()) {
            self.hubClient = hubClient
        }

        // MARK: Public

        /// Download (or verify already-cached) a model and return its
        /// loaded `ModelContainer`. The async stream surfaces progress
        /// updates; the returned container is available once the stream
        /// completes successfully.
        ///
        /// Use `useLatest: true` to force a remote check even when the
        /// model is already cached — useful for "update available?" flows.
        public func loadContainer(
            id: String,
            revision: String = "main",
            useLatest: Bool = false,
            onProgress: @Sendable @escaping (MLXDownloadProgress) -> Void = { _ in }
        ) async throws -> ModelContainer {
            try await MLXLMTransformers.loadModelContainer(
                from: self.hubClient,
                id: id,
                revision: revision,
                useLatest: useLatest,
                progressHandler: { progress in
                    onProgress(MLXDownloadProgress(progress: progress))
                }
            )
        }

        /// Streaming version: yields `MLXDownloadProgress` ticks as the
        /// download advances. The returned async sequence finishes once
        /// the download completes; call `loadContainer` separately to
        /// obtain the `ModelContainer` (or use `loadContainer` above
        /// which surfaces both).
        public func progressStream(
            id: String,
            revision: String = "main",
            useLatest: Bool = false
        ) -> AsyncThrowingStream<MLXDownloadProgress, any Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        _ = try await self.loadContainer(
                            id: id,
                            revision: revision,
                            useLatest: useLatest,
                            onProgress: { tick in continuation.yield(tick) }
                        )
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        // MARK: Private

        private let hubClient: HubClient
    }
#endif
