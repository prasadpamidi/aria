#if canImport(MLXLMCommon)
    import Foundation
    import HuggingFace
    import MLXLLM
    import MLXLMCommon
    import MLXLMHuggingFace
    import MLXLMTransformers
    import MLXVLM

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

        public init(hubClient: HubClient = MLXModelDownloader.defaultHubClient()) {
            self.hubClient = hubClient
        }

        // MARK: Public

        /// Default on-disk root for downloaded models:
        /// `Documents/huggingface/hub/`. We pin this rather than letting
        /// `HubClient` fall back to its default `Library/Caches/...`
        /// because iOS evicts `Caches` under storage pressure and a
        /// multi-GB redownload is the kind of surprise users notice.
        /// `MLXModelDiskManager` reads from the same root.
        public static func defaultCacheDirectory() -> URL {
            let documents = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            return documents
                .appendingPathComponent("huggingface", isDirectory: true)
                .appendingPathComponent("hub", isDirectory: true)
        }

        /// `HubClient` configured with `defaultCacheDirectory()`.
        public static func defaultHubClient() -> HubClient {
            HubClient(cache: HubCache(cacheDirectory: self.defaultCacheDirectory()))
        }

        /// Download (or verify already-cached) a model and return its
        /// loaded `ModelContainer`. The async stream surfaces progress
        /// updates; the returned container is available once the stream
        /// completes successfully.
        ///
        /// Use `useLatest: true` to force a remote check even when the
        /// model is already cached — useful for "update available?" flows.
        public func loadContainer(
            id: String,
            kind: MLXModelKind = .textOnly,
            revision: String = "main",
            useLatest: Bool = false,
            toolCallFormat: ToolCallFormat? = nil,
            onProgress: @Sendable @escaping (MLXDownloadProgress) -> Void = { _ in }
        ) async throws -> ModelContainer {
            let factory: any GenericModelFactory<ModelContext, ModelContainer> = (kind == .vision)
                ? VLMModelFactory.shared
                : LLMModelFactory.shared
            // Override mlx-swift-lm's `ToolCallFormat.infer` when the
            // catalog knows the model's chat-template format (Qwen 2.5,
            // Qwen 2.5 VL, Gemma 2, etc. report `model_type` strings
            // the inferrer doesn't cover).
            let configuration = ModelConfiguration(
                id: id,
                revision: revision,
                toolCallFormat: toolCallFormat
            )
            return try await factory.loadContainer(
                from: self.hubClient,
                using: TransformersLoader(),
                configuration: configuration,
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
            kind: MLXModelKind = .textOnly,
            revision: String = "main",
            useLatest: Bool = false,
            toolCallFormat: ToolCallFormat? = nil
        ) -> AsyncThrowingStream<MLXDownloadProgress, any Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        _ = try await self.loadContainer(
                            id: id,
                            kind: kind,
                            revision: revision,
                            useLatest: useLatest,
                            toolCallFormat: toolCallFormat,
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
