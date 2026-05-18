import Foundation
import Network
import Observation
import OSLog
import UIKit

#if canImport(AriaMLX)
    import AriaMLX
#endif

// MARK: - Logging

/// Common log channel for the whole download pipeline. Tail with:
///
///     log stream --predicate 'subsystem == "com.3theories.app.Avyra" \
///         && category == "Download"' --level debug
///
/// Every line is prefixed `[Avyra/DL]` so it reads well in mixed
/// stdout output too.
///
/// `nonisolated` because the project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
/// — file-scope constants would otherwise be MainActor-isolated and
/// unreachable from background Tasks. `Logger` is `Sendable` so this
/// is safe.
private nonisolated let downloadLog = Logger(
    subsystem: "com.3theories.app.Avyra",
    category: "Download"
)

// MARK: - DownloadCoordinator

/// App-scoped owner of MLX model download tasks. Centralizes three
/// concerns that were previously tangled inside the picker:
///
///   1. **Task ownership** — `Task<Void, Never>` per modelId, so a
///      download survives the user navigating off the family detail
///      screen back to the picker root or even to chat.
///   2. **Progress state** — single source of truth observed by the
///      picker rows, the "downloading" banner, and any other surface.
///   3. **Side effects** — toggles `UIApplication.isIdleTimerDisabled`
///      and runs a `NWPathMonitor` for log correlation.
///
/// Per-download work spins three sidecar `Task`s (SDK stream, disk
/// poller, stall watchdog) plus a heartbeat. Each lives only as long
/// as the parent `Task<Void, Never>` — `defer` cancels them all on
/// exit, so cancellation is deterministic.
@MainActor
@Observable
final class DownloadCoordinator {
    // MARK: Lifecycle

    init() {
        self.pathMonitor = Self.makeNetworkMonitor()
    }

    // MARK: Internal

    // MARK: - Observable state

    /// Snapshot of one in-flight download, observed by every UI
    /// surface that wants to render progress.
    struct ActiveDownload: Equatable {
        let modelId: String
        let displayName: String
        /// Bytes already on disk. Updated from **two** sources:
        ///   1. SDK progress callback — fires at file-completion
        ///      boundaries.
        ///   2. Disk poller — walks the model's HF cache dir every
        ///      second and reports live file size, including the
        ///      in-flight shard the SDK callback won't tell us about
        ///      until completion.
        /// We always take `max(SDK, disk)`.
        var completedBytes: Int64
        /// Total size of the download, once HF finishes the snapshot
        /// manifest walk. `nil` for the first few hundred ms.
        var totalBytes: Int64?
        /// `0.0…1.0`, or `nil` while `totalBytes` is unknown.
        var fraction: Double?
        /// Transfer rate in bytes/sec, smoothed over a ~5 s window.
        var bytesPerSecond: Double?
        /// Estimated seconds remaining, derived from rate + remaining
        /// bytes. `nil` when we don't have both yet.
        var etaSeconds: TimeInterval?

        var isIndeterminate: Bool {
            self.fraction == nil
        }
    }

    // MARK: - Tunables

    /// Max time without byte progress before we auto-cancel a
    /// download. swift-huggingface can legitimately go silent for a
    /// few minutes mid-shard, but ≥3 min usually means the underlying
    /// URLSession transfer is wedged. Cancel + surface an actionable
    /// error beats hanging forever.
    static let stallTimeout: TimeInterval = 180

    /// All currently-downloading models, keyed by Hugging Face id.
    private(set) var active: [String: ActiveDownload] = [:]

    var hasActiveDownloads: Bool {
        !self.active.isEmpty
    }

    func snapshot(for modelId: String) -> ActiveDownload? {
        self.active[modelId]
    }

    func isDownloading(_ modelId: String) -> Bool {
        self.active[modelId] != nil
    }

    // MARK: - Public API

    #if canImport(AriaMLX)
        /// Kick off a download for `variant`. No-op if a download for
        /// this id is already running.
        func start(
            variant: MLXModelCapabilities,
            manager: MLXModelManager,
            onCompleted: @escaping @MainActor () -> Void = { },
            onFailed: @escaping @MainActor (String) -> Void = { _ in }
        ) {
            guard self.tasks[variant.id] == nil else {
                return
            }
            downloadLog.info("[Avyra/DL] start \(variant.displayName, privacy: .public)")
            self.active[variant.id] = ActiveDownload(
                modelId: variant.id,
                displayName: variant.displayName,
                completedBytes: 0,
                totalBytes: nil,
                fraction: nil,
                bytesPerSecond: nil,
                etaSeconds: nil
            )
            self.updateIdleTimer()
            self.tasks[variant.id] = Task { [weak self] in
                await self?.runDownload(
                    variant: variant,
                    manager: manager,
                    onCompleted: onCompleted,
                    onFailed: onFailed
                )
            }
        }
    #endif

    /// Cancel an in-flight download. The `start` loop notices via
    /// `Task.isCancelled` and cleans state in its `defer`.
    func cancel(modelId: String) {
        self.tasks[modelId]?.cancel()
    }

    // MARK: Fileprivate

    // MARK: - Private — file helpers

    #if canImport(AriaMLX)
        /// Path to the model's HF cache repo dir. swift-huggingface
        /// names directories `models--<org>--<name>` (mirroring the
        /// Python `huggingface_hub` layout). Used by the disk poller.
        fileprivate static nonisolated func huggingfaceRepoDir(for modelId: String) -> URL {
            let safe = modelId.replacingOccurrences(of: "/", with: "--")
            return MLXModelDiskManager.defaultRoot()
                .appendingPathComponent("models--\(safe)", isDirectory: true)
        }
    #endif

    /// Recursive size of a directory. Returns 0 if the directory
    /// doesn't exist yet (created lazily by the SDK on first byte).
    fileprivate static nonisolated func directorySize(at url: URL) -> Int64 {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return 0
        }
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true, let size = values?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// Short human form for log lines — "1.39 GB", "17 MB".
    fileprivate static nonisolated func formatBytesShort(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: Private

    // MARK: - Private — legs

    /// One outcome enum so the orchestrator can dispatch correctly
    /// without sprinkling `if-let-error` checks.
    private enum SDKOutcome {
        case completed
        case cancelled
        case failed(Error)
    }

    /// How often the stall watcher polls.
    private static let stallCheckInterval: TimeInterval = 10

    // MARK: - Private state

    private var tasks: [String: Task<Void, Never>] = [:]
    private var pathMonitor: NWPathMonitor?

    /// Background network monitor — logs path changes so download
    /// stalls can be correlated with Wi-Fi/cellular handoffs.
    private static func makeNetworkMonitor() -> NWPathMonitor {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let kind =
                if path.usesInterfaceType(.wifi) {
                    "wifi"
                } else if path.usesInterfaceType(.cellular) {
                    "cellular"
                } else if path.usesInterfaceType(.wiredEthernet) {
                    "ethernet"
                } else {
                    "other"
                }
            downloadLog.notice(
                "[Avyra/DL] network \(String(describing: path.status), privacy: .public) via \(kind, privacy: .public)"
            )
        }
        monitor.start(queue: .global(qos: .utility))
        return monitor
    }

    // MARK: - Private — orchestrator

    #if canImport(AriaMLX)
        /// One download's full lifecycle. Spins up four concurrent
        /// legs (SDK stream + disk poller + stall watchdog +
        /// heartbeat) as siblings, then awaits the SDK leg as the
        /// driver — when it returns the `defer`s tear the sidecars
        /// down.
        private func runDownload(
            variant: MLXModelCapabilities,
            manager: MLXModelManager,
            onCompleted: @escaping @MainActor () -> Void,
            onFailed: @escaping @MainActor (String) -> Void
        ) async {
            let startedAt = Date()
            let progress = DownloadProgressTracker()

            // Sidecar 1 — disk poller. Reads the cache dir each
            // second so mid-shard byte progress shows up in the UI
            // even when the SDK callback is silent.
            let repoDir = Self.huggingfaceRepoDir(for: variant.id)
            let poller = Task { [weak self] in
                await self?.runDiskPoller(
                    modelId: variant.id,
                    repoDir: repoDir,
                    progress: progress
                )
            }
            defer { poller.cancel() }

            // Sidecar 2 — stall watchdog. Cancels the parent task
            // if no byte progress for `stallTimeout`.
            let watchdog = Task { [weak self] in
                await self?.runStallWatchdog(
                    modelId: variant.id,
                    progress: progress
                )
            }
            defer { watchdog.cancel() }

            // Sidecar 3 — heartbeat. "Still alive" log every 15 s.
            let heartbeat = Task { [weak self] in
                await self?.runHeartbeat(
                    modelId: variant.id,
                    startedAt: startedAt,
                    progress: progress
                )
            }
            defer { heartbeat.cancel() }

            // Driver — SDK progress stream. Returns when transfer
            // completes (success), cancelled, or throws.
            let outcome = await self.runSDKStream(
                variant: variant,
                manager: manager,
                progress: progress
            )
            self.finish(
                modelId: variant.id,
                outcome: outcome,
                startedAt: startedAt,
                onCompleted: onCompleted,
                onFailed: onFailed
            )
        }
    #endif

    #if canImport(AriaMLX)
        /// Drain the SDK's progress stream. Merges into the shared
        /// `DownloadProgressTracker` and the Observable state.
        private func runSDKStream(
            variant: MLXModelCapabilities,
            manager: MLXModelManager,
            progress: DownloadProgressTracker
        ) async -> SDKOutcome {
            var fileBoundaryCount = 0
            do {
                for try await tick in manager.downloadProgress(for: variant.id) {
                    if Task.isCancelled {
                        return .cancelled
                    }
                    let prev = progress.completedBytes
                    if tick.completed > prev {
                        fileBoundaryCount += 1
                        let totalStr = tick.total.map { Self.formatBytesShort($0) } ?? "—"
                        let delta = tick.completed - prev
                        downloadLog.info(
                            "[Avyra/DL] file #\(fileBoundaryCount) \(variant.id, privacy: .public) +\(Self.formatBytesShort(delta), privacy: .public) → \(Self.formatBytesShort(tick.completed), privacy: .public) / \(totalStr, privacy: .public)"
                        )
                    }
                    progress.recordBytes(tick.completed, total: tick.total, at: Date())
                    self.applyProgress(progress, to: variant.id)
                }
                return .completed
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .failed(error)
            }
        }
    #endif

    /// Polls the model's HF cache dir for real byte progress. This
    /// is what gives the UI smooth mid-shard updates the SDK
    /// callback alone wouldn't provide.
    private func runDiskPoller(
        modelId: String,
        repoDir: URL,
        progress: DownloadProgressTracker
    ) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled {
                return
            }
            let bytes = Self.directorySize(at: repoDir)
            guard bytes > progress.completedBytes else {
                continue
            }
            progress.recordBytes(bytes, total: progress.totalBytes, at: Date())
            self.applyProgress(progress, to: modelId)
        }
    }

    /// Cancels the parent download Task if no byte progress arrives
    /// for `stallTimeout` seconds. Surfaces as a `CancellationError`
    /// in `runSDKStream`, which we map to `.cancelled` + a friendly
    /// error in `finish`.
    private func runStallWatchdog(
        modelId: String,
        progress: DownloadProgressTracker
    ) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.stallCheckInterval))
            if Task.isCancelled {
                return
            }
            let stalled = Date().timeIntervalSince(progress.lastByteChangeAt)
            if stalled >= Self.stallTimeout {
                downloadLog.error(
                    "[Avyra/DL] timeout \(modelId, privacy: .public) — no byte progress for \(String(format: "%.0f", stalled))s, cancelling"
                )
                self.tasks[modelId]?.cancel()
                return
            }
        }
    }

    /// Periodic "still here" log so silent-but-alive looks different
    /// from genuinely wedged in the replay.
    private func runHeartbeat(
        modelId: String,
        startedAt: Date,
        progress: DownloadProgressTracker
    ) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(15))
            if Task.isCancelled {
                return
            }
            let elapsed = Date().timeIntervalSince(startedAt)
            let totalStr = progress.totalBytes.map { Self.formatBytesShort($0) } ?? "—"
            downloadLog.notice(
                "[Avyra/DL] heartbeat \(modelId, privacy: .public) \(Self.formatBytesShort(progress.completedBytes), privacy: .public) / \(totalStr, privacy: .public) elapsed=\(String(format: "%.0f", elapsed))s"
            )
        }
    }

    // MARK: - Private — state updates

    /// Reflect the latest tracker snapshot into the Observable state.
    /// Always idempotent / non-decreasing on bytes, so a late SDK
    /// callback can't lower the count below the disk poller's reading.
    private func applyProgress(_ progress: DownloadProgressTracker, to modelId: String) {
        guard var snap = self.active[modelId] else {
            return
        }
        snap.completedBytes = max(snap.completedBytes, progress.completedBytes)
        snap.totalBytes = progress.totalBytes ?? snap.totalBytes
        snap.bytesPerSecond = progress.bytesPerSecond
        snap.etaSeconds = progress.etaSeconds
        if let total = snap.totalBytes, total > 0 {
            snap.fraction = min(1.0, Double(snap.completedBytes) / Double(total))
        }
        self.active[modelId] = snap
    }

    /// Tear down state + log the outcome.
    private func finish(
        modelId: String,
        outcome: SDKOutcome,
        startedAt: Date,
        onCompleted: @escaping @MainActor () -> Void,
        onFailed: @escaping @MainActor (String) -> Void
    ) {
        let elapsed = Date().timeIntervalSince(startedAt)
        let lastSnap = self.active[modelId]
        self.tasks[modelId] = nil
        self.active[modelId] = nil
        self.updateIdleTimer()

        switch outcome {
        case .completed:
            let bytes = lastSnap.map { Self.formatBytesShort($0.completedBytes) } ?? "—"
            downloadLog.info(
                "[Avyra/DL] finished \(modelId, privacy: .public) bytes=\(bytes, privacy: .public) in \(String(format: "%.1f", elapsed))s"
            )
            onCompleted()
        case .cancelled:
            downloadLog.notice("[Avyra/DL] cancelled \(modelId, privacy: .public)")
        case let .failed(error):
            downloadLog.error(
                "[Avyra/DL] failed \(modelId, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            onFailed("Download failed: \(error.localizedDescription)")
        }
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = !self.active.isEmpty
    }
}

// MARK: - DownloadProgressTracker

/// Mutable, MainActor-isolated container that the SDK leg, disk
/// poller, and stall watchdog all read/write to. Holds the merged
/// view of "current best-known progress" plus a rolling rate
/// window so the orchestrator can compute ETA in one place.
///
/// Lives on the MainActor implicitly because the project's default
/// isolation is MainActor — and the sidecars all run their state
/// mutations through the coordinator's `applyProgress(_:to:)`, so
/// only the MainActor touches this directly.
@MainActor
final class DownloadProgressTracker {
    // MARK: Lifecycle

    init() {
        self.lastByteChangeAt = Date()
        self.lastEtaSampledAt = Date()
    }

    // MARK: Internal

    // MARK: - State

    private(set) var completedBytes: Int64 = 0
    private(set) var totalBytes: Int64?
    private(set) var lastByteChangeAt: Date

    var bytesPerSecond: Double? {
        self.currentRate
    }

    /// Monotonically-decreasing ETA. The raw `total/rate` calculation
    /// jitters wildly between file boundaries (rate spikes to 0 →
    /// "infinity remaining"), which reads as "ETA going up." We
    /// only ever *lower* the displayed ETA; otherwise we keep the
    /// last estimate and decrement it by wall-clock elapsed time.
    /// Effect: countdown that's optimistic if the real rate has
    /// dropped, but never jumps backwards.
    var etaSeconds: TimeInterval? {
        let now = Date()
        defer { self.lastEtaSampledAt = now }
        let elapsed = now.timeIntervalSince(self.lastEtaSampledAt)
        let rawEta = self.computeRawEta()

        if let raw = rawEta {
            if let prior = self.displayedEta {
                // Allow drop OR a small "creep" of a couple seconds —
                // smooth slowdowns shouldn't lock to the old estimate.
                let priorAdvanced = max(0, prior - elapsed)
                self.displayedEta = min(priorAdvanced, raw)
            } else {
                self.displayedEta = raw
            }
        } else if let prior = self.displayedEta {
            // No fresh ETA (rate dropped to zero / no samples yet).
            // Keep counting down so the UI doesn't look frozen.
            self.displayedEta = max(0, prior - elapsed)
        }
        return self.displayedEta
    }

    // MARK: - Mutation

    /// Record a new observation. Always non-decreasing on bytes —
    /// late SDK callbacks can't lower the count if the disk poller
    /// has already moved past them.
    func recordBytes(_ completed: Int64, total: Int64?, at time: Date) {
        if completed > self.completedBytes {
            self.completedBytes = completed
            self.lastByteChangeAt = time
            self.appendRateSample(bytes: completed, at: time)
        }
        if let total {
            self.totalBytes = total
        }
    }

    // MARK: Private

    // MARK: - Rate window

    private struct RateSample {
        let at: Date
        let bytes: Int64
    }

    private static let windowSeconds: TimeInterval = 15

    private var displayedEta: TimeInterval?
    private var lastEtaSampledAt: Date

    /// 15 s window — long enough that file-boundary spikes don't
    /// dominate, short enough to follow a real slowdown.
    private var samples: [RateSample] = []

    private var currentRate: Double? {
        guard let oldest = self.samples.first,
              self.samples.count >= 2 else {
            return nil
        }
        let dt = Date().timeIntervalSince(oldest.at)
        guard dt > 0.5 else {
            return nil
        }
        let dBytes = Double(self.completedBytes - oldest.bytes)
        guard dBytes > 0 else {
            return 0
        }
        return dBytes / dt
    }

    private func appendRateSample(bytes: Int64, at time: Date) {
        self.samples.append(RateSample(at: time, bytes: bytes))
        let cutoff = time.addingTimeInterval(-Self.windowSeconds)
        self.samples.removeAll { $0.at < cutoff }
    }

    private func computeRawEta() -> TimeInterval? {
        guard let total = self.totalBytes,
              total > self.completedBytes,
              let rate = self.currentRate, rate > 0 else {
            return nil
        }
        return Double(total - self.completedBytes) / rate
    }
}
