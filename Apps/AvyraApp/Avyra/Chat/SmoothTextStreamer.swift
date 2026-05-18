import Foundation
import Observation

// MARK: - SmoothTextStreamer

/// Buffers raw `.textDelta` chunks from a provider and drains them
/// into a `displayed` string at a steady cadence, so the chat bubble
/// reads as a fluid typewriter instead of a burst of characters every
/// time a network chunk lands.
///
/// **The problem.** LLM providers don't emit one character per
/// packet — they batch 1-20 tokens per network chunk depending on
/// model speed, context window pressure, and connection jitter. The
/// naive approach (`Text(transcript[last].content)` re-rendered on
/// every delta) produces a visibly stuttering "burst, pause, burst"
/// effect that feels broken.
///
/// **The fix.** Decouple network from display:
///
///   1. Provider deltas append to `pending` (zero UI work).
///   2. A drain `Task` wakes every `tickInterval` and moves a few
///      characters from `pending` → `displayed`.
///   3. The bubble observes `displayed` via SwiftUI's `@Observable`
///      machinery and animates the change.
///
/// **Adaptive batch size.** When the buffer is deep (a fast model
/// dumped 80 chars at once), we drain more per tick so we don't fall
/// arbitrarily far behind the actual response. When it's shallow we
/// drain ~1 char per tick so the user reads at a comfortable pace.
/// Pull values were tuned against Apple Intelligence + a few MLX
/// catalog models; reasonable defaults — open to per-provider tuning
/// later.
///
/// References:
///   - Vercel AI SDK `experimental_smoothStream` (20ms / word-level)
///   - Stream Chat StreamingMessageView (character-level)
///   - ChatGPT's web client (decoupled queue + rAF-paced drain)
@MainActor
@Observable
final class SmoothTextStreamer {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - tickInterval: How often the drain task wakes. 25 ms is a
    ///     comfortable balance — fast enough to look continuous,
    ///     slow enough to keep render churn under control.
    ///   - minBatchSize: Minimum characters drained per tick.
    ///     Always ≥1; bumping to 2 makes the typewriter feel snappier
    ///     for slow models but loses some "typing" feel.
    ///   - maxBatchSize: Cap on characters per tick so a giant chunk
    ///     doesn't appear all at once.
    ///   - batchDivisor: `pending.count / batchDivisor` is the target
    ///     batch — buffer-aware so we catch up during fast bursts.
    init(
        tickInterval: Duration = .milliseconds(25),
        minBatchSize: Int = 1,
        maxBatchSize: Int = 12,
        batchDivisor: Int = 8
    ) {
        self.tickInterval = tickInterval
        self.minBatchSize = minBatchSize
        self.maxBatchSize = maxBatchSize
        self.batchDivisor = max(1, batchDivisor)
    }

    // No `deinit` — `@MainActor` isolation makes touching
    // `drainTask` from a nonisolated deinit a Swift 6 error, and we
    // don't actually need one: the drain `Task` captures `[weak
    // self]`, so the next tick after dealloc no-ops and the task
    // exits on its own.

    // MARK: Internal

    /// What the bubble should render right now. Grows as the drain
    /// task pulls characters off `pending`.
    private(set) var displayed: String = ""

    /// Drop any pending or displayed text and stop the drain task.
    /// Call at the start of each new turn.
    func reset() {
        self.drainTask?.cancel()
        self.drainTask = nil
        self.displayed = ""
        self.pending = ""
    }

    /// Feed a raw provider delta. Zero UI work — the chunk just
    /// queues up. The drain task wakes (if not already running) and
    /// starts pushing characters into `displayed` on the next tick.
    func append(_ chunk: String) {
        guard !chunk.isEmpty else {
            return
        }
        self.pending += chunk
        self.startDrainIfNeeded()
    }

    /// Immediately flush the remaining buffer to `displayed`. Call
    /// when the stream finishes (or on an error) so the user doesn't
    /// stare at an artificial trailing typewriter delay.
    func flush() {
        self.drainTask?.cancel()
        self.drainTask = nil
        guard !self.pending.isEmpty else {
            return
        }
        self.displayed += self.pending
        self.pending = ""
    }

    // MARK: Private

    private let tickInterval: Duration
    private let minBatchSize: Int
    private let maxBatchSize: Int
    private let batchDivisor: Int

    /// Tokens received from the provider but not yet shown.
    private var pending: String = ""

    /// The drain loop. Reset to `nil` whenever the buffer empties so
    /// the next `append` can spin it back up.
    private var drainTask: Task<Void, Never>?

    private func startDrainIfNeeded() {
        guard self.drainTask == nil else {
            return
        }
        self.drainTask = Task { [weak self] in
            await self?.drainLoop()
        }
    }

    private func drainLoop() async {
        while !Task.isCancelled, !self.pending.isEmpty {
            let batch = self.nextBatchSize()
            let take = self.pending.prefix(batch)
            self.displayed += take
            self.pending = String(self.pending.dropFirst(take.count))
            do {
                try await Task.sleep(for: self.tickInterval)
            } catch {
                break
            }
        }
        self.drainTask = nil
    }

    /// Adaptive batch sizing: bigger when we're behind, smaller when
    /// we're close to caught up. Clamped to [min, max].
    private func nextBatchSize() -> Int {
        let dynamic = self.pending.count / self.batchDivisor
        return max(self.minBatchSize, min(self.maxBatchSize, dynamic))
    }
}
