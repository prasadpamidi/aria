#if ARIA_VOICE_KOKORO
    import AriaVoice
    import Foundation
    import OSLog

    // MARK: - KokoroAssetSource

    /// Where to fetch the two Kokoro artifacts from, where to persist
    /// them, and what sizes count as "valid" on-disk. Apps can supply
    /// their own source to host the assets behind their CDN, pin a
    /// specific model version, or place them under a different
    /// directory than `Application Support/kokoro/`.
    ///
    /// Sendable + immutable so it can be passed across actor boundaries
    /// without copy concerns.
    public struct KokoroAssetSource: Sendable {
        // MARK: Lifecycle

        public init(
            voicesDownloadURL: URL,
            modelDownloadURL: URL,
            voicesPath: URL,
            modelPath: URL,
            voicesMinSize: Int64,
            modelMinSize: Int64
        ) {
            self.voicesDownloadURL = voicesDownloadURL
            self.modelDownloadURL = modelDownloadURL
            self.voicesPath = voicesPath
            self.modelPath = modelPath
            self.voicesMinSize = voicesMinSize
            self.modelMinSize = modelMinSize
        }

        // MARK: Public

        /// Default source: HuggingFace + GitHub upstream URLs, files
        /// saved under `Application Support/kokoro/`. Matches the
        /// configuration the package shipped with originally.
        public static let `default`: KokoroAssetSource = {
            // swiftlint:disable force_unwrapping
            let voicesURL = URL(
                string: "https://github.com/mlalma/KokoroTestApp/raw/main/Resources/voices.npz"
            )!
            let modelURL = URL(
                string: "https://huggingface.co/prince-canuma/Kokoro-82M/resolve/main/kokoro-v1_0.safetensors"
            )!
            // swiftlint:enable force_unwrapping
            let dir = Self.defaultDirectory()
            return KokoroAssetSource(
                voicesDownloadURL: voicesURL,
                modelDownloadURL: modelURL,
                voicesPath: dir.appendingPathComponent("voices.npz", isDirectory: false),
                modelPath: dir.appendingPathComponent("kokoro-v1_0.safetensors", isDirectory: false),
                voicesMinSize: 5 * 1024 * 1024,
                modelMinSize: 200 * 1024 * 1024
            )
        }()

        public let voicesDownloadURL: URL
        public let modelDownloadURL: URL
        public let voicesPath: URL
        public let modelPath: URL
        public let voicesMinSize: Int64
        public let modelMinSize: Int64

        /// Where the default source places artifacts on disk. Exposed so
        /// callers building a custom `KokoroAssetSource` can re-use the
        /// directory if they only want to override the download URLs.
        public static func defaultDirectory() -> URL {
            // swiftlint:disable:next force_try
            let support = try! FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            return support.appendingPathComponent("kokoro", isDirectory: true)
        }
    }

    // MARK: - KokoroAssetManager

    /// Downloads + tracks the two files Kokoro TTS needs at runtime:
    ///
    ///   1. `kokoro-v1_0.safetensors` (~327MB) — the TTS model weights.
    ///   2. `voices.npz` (~14MB) — bundled voice embeddings keyed by
    ///      voice id.
    ///
    /// Where exactly those come from and where they land on disk is
    /// controlled by the `KokoroAssetSource` passed at init. The default
    /// pulls from HuggingFace + a public GitHub raw URL and persists
    /// under `Application Support/kokoro/`; consumer apps can supply
    /// their own source to mirror through a CDN, pin specific versions,
    /// or change the destination directory.
    ///
    /// The manager is `@Observable` so UIs can render live progress
    /// bars without manual subscription wiring.
    ///
    /// Cancellation: the download `Task` retains its own
    /// `URLSessionDownloadTask` and tears down on `cancelDownload()`.
    /// Partial files are deleted so a half-finished download can't
    /// satisfy `isReady` checks on the next launch.
    @MainActor
    @Observable
    public final class KokoroAssetManager {
        // MARK: Lifecycle

        public init(source: KokoroAssetSource = .default) {
            self.source = source
            self.refreshStatus()
        }

        // MARK: Public

        public enum Status: Equatable, Sendable {
            case notDownloaded
            case downloading(Phase, Double)
            case ready
            case failed(String)
        }

        public enum Phase: String, Equatable, Sendable {
            case voices
            case model

            // MARK: Public

            public var displayName: String {
                switch self {
                case .voices: "Voices"
                case .model: "Model"
                }
            }
        }

        public let source: KokoroAssetSource

        public private(set) var status: Status = .notDownloaded
        public private(set) var modelURL: URL?
        public private(set) var voicesURL: URL?

        /// `true` once both files exist on disk at their expected paths
        /// and pass a minimum-size sanity check (catches the case
        /// where a partial download left a tiny placeholder behind).
        public var isReady: Bool {
            if case .ready = self.status {
                return true
            }
            return false
        }

        /// Stateless file removal. Exposed as a static so callers that
        /// don't hold an `@Observable` manager (e.g. a bulk storage-
        /// management screen) can wipe Kokoro assets without spinning
        /// up a throwaway instance just to call the instance method.
        /// Defaults to the standard source's paths.
        public static func wipeAssetsOnDisk(source: KokoroAssetSource = .default) {
            self.deleteIfPresent(at: source.voicesPath)
            self.deleteIfPresent(at: source.modelPath)
        }

        /// Download both files in order: voices first (small, ~14MB),
        /// then model (large, ~327MB). Splitting the phases means the
        /// progress bar moves visibly during the small file too,
        /// instead of sitting at 0% for the entire model fetch.
        public func startDownload() {
            // Re-entrancy guard — don't kick off a second download
            // while one is already in flight.
            if case .downloading = self.status {
                return
            }
            self.downloadTask = Task { [weak self] in
                await self?.runDownload()
            }
        }

        public func cancelDownload() {
            self.downloadTask?.cancel()
            self.downloadTask = nil
            self.activeURLTask?.cancel()
            self.activeURLTask = nil
            self.refreshStatus()
        }

        /// Wipe both files. Used by "Delete Kokoro model" controls;
        /// resets `status` so the user can re-download.
        public func deleteAssets() {
            Self.wipeAssetsOnDisk(source: self.source)
            self.refreshStatus()
        }

        /// Re-check disk state. Called on init and after any mutation
        /// so the UI reflects the truth even if a download finished
        /// while the view was off screen.
        public func refreshStatus() {
            let voicesOK = FileManager.default.fileExists(atPath: self.source.voicesPath.path)
                && Self.fileSize(at: self.source.voicesPath) > self.source.voicesMinSize
            let modelOK = FileManager.default.fileExists(atPath: self.source.modelPath.path)
                && Self.fileSize(at: self.source.modelPath) > self.source.modelMinSize
            if voicesOK, modelOK {
                self.status = .ready
                self.voicesURL = self.source.voicesPath
                self.modelURL = self.source.modelPath
            } else {
                self.status = .notDownloaded
                self.voicesURL = nil
                self.modelURL = nil
            }
        }

        // MARK: Private

        private var downloadTask: Task<Void, Never>?
        private var activeURLTask: URLSessionDownloadTask?

        private static func ensureDirectory(_ url: URL) throws {
            if !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: true
                )
            }
        }

        private static func deleteIfPresent(at url: URL) {
            guard FileManager.default.fileExists(atPath: url.path) else {
                return
            }
            try? FileManager.default.removeItem(at: url)
        }

        private static func fileSize(at url: URL) -> Int64 {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }

        private func runDownload() async {
            do {
                try await self.downloadIfMissing(
                    from: self.source.voicesDownloadURL,
                    to: self.source.voicesPath,
                    phase: .voices,
                    minSize: self.source.voicesMinSize
                )
                try await self.downloadIfMissing(
                    from: self.source.modelDownloadURL,
                    to: self.source.modelPath,
                    phase: .model,
                    minSize: self.source.modelMinSize
                )
                self.refreshStatus()
            } catch is CancellationError {
                voiceLog.notice("[Voice/Kokoro] download cancelled")
                self.refreshStatus()
            } catch {
                voiceLog
                    .error(
                        "[Voice/Kokoro] download failed: \(error.localizedDescription, privacy: .public)"
                    )
                self.status = .failed(error.localizedDescription)
            }
        }

        /// One-file downloader. Streams the response with a
        /// `URLSessionDownloadTask` (memory-stable for 300MB+ files)
        /// and emits progress at ~10Hz into `self.status`. Persists to
        /// `destination` once the byte count clears `minSize` — the
        /// guard against partial / placeholder files.
        private func downloadIfMissing(
            from source: URL,
            to destination: URL,
            phase: Phase,
            minSize: Int64
        ) async throws {
            if FileManager.default.fileExists(atPath: destination.path),
               Self.fileSize(at: destination) > minSize {
                return
            }
            try Self.ensureDirectory(destination.deletingLastPathComponent())

            self.status = .downloading(phase, 0)

            let (tmpURL, response) = try await self.runDownloadTask(
                source: source,
                phase: phase
            )

            // `runDownloadTask` doesn't expose HTTP status; check it
            // here so a 4xx body doesn't masquerade as a successful
            // download just because it landed at a path.
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw NSError(
                    domain: "KokoroAssetManager",
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) from \(source.lastPathComponent)"]
                )
            }

            // Move from tmp into our app-support cache. URLSession's
            // tmp path is invalidated as soon as we return from the
            // delegate, so the move has to happen synchronously.
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: tmpURL, to: destination)

            // Don't back up to iCloud — these are recoverable assets.
            var noBackup = destination
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? noBackup.setResourceValues(values)
        }

        /// Bridges `URLSessionDownloadTask`'s callback API into async/await
        /// while exposing per-byte progress. Standard `URLSession.download`
        /// (the async one) doesn't surface progress, so we use the
        /// classic delegate-free pattern with `progress(of:)` polling.
        private func runDownloadTask(
            source: URL,
            phase: Phase
        ) async throws -> (URL, URLResponse) {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<
                    (URL, URLResponse),
                    any Error
                >) in
                    let session = URLSession.shared
                    let task = session.downloadTask(with: source) { [weak self] tmpURL, response, error in
                        if let error {
                            continuation.resume(throwing: error)
                            return
                        }
                        guard let tmpURL, let response else {
                            continuation.resume(
                                throwing: NSError(
                                    domain: "KokoroAssetManager",
                                    code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "Download returned no data."]
                                )
                            )
                            return
                        }
                        // Pin a copy so the system tmp doesn't get
                        // reclaimed while we hop to MainActor.
                        let pinned = tmpURL.appendingPathExtension("kokoro-download")
                        try? FileManager.default.moveItem(at: tmpURL, to: pinned)
                        // Re-capture `self` weakly when crossing into
                        // the actor-hop Task. The outer URLSession
                        // callback already captured `self?`, but
                        // Swift 6 treats each closure boundary as a
                        // separate concurrent context and refuses to
                        // re-use a capture from the enclosing scope.
                        Task { @MainActor [weak self] in
                            self?.activeURLTask = nil
                            continuation.resume(returning: (pinned, response))
                        }
                    }
                    self.activeURLTask = task
                    self.observeProgress(of: task, phase: phase)
                    task.resume()
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.activeURLTask?.cancel()
                    self?.activeURLTask = nil
                }
            }
        }

        /// KVO substitute via a polling Task. URLSession's `progress`
        /// is a `Progress` object whose `fractionCompleted` updates as
        /// bytes land; polling at 10Hz is cheap and avoids the KVO
        /// boilerplate.
        private func observeProgress(of task: URLSessionDownloadTask, phase: Phase) {
            Task { @MainActor [weak self] in
                while !Task.isCancelled,
                      task.state == .running || task.state == .suspended {
                    let fraction = task.progress.fractionCompleted
                    if let self {
                        self.status = .downloading(phase, fraction)
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
    }
#endif
