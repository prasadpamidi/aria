import Foundation
import Observation

// MARK: - TranscriptInbox

/// One-way side channel from the middleware chain back into the
/// chat transcript. Middleware callbacks (e.g. `RAGMiddleware.onRecall`)
/// are `@Sendable` closures that fire on a background actor; they can't
/// safely capture a `View` struct because View's transitive stored
/// properties (GRDB storage, app state, recorders) may not all be
/// `Sendable`.
///
/// Holding the per-turn handoff on a tiny `@Observable` reference type
/// gives the closure something cheap and `Sendable`-friendly to capture.
/// The view watches this inbox and drains it into the active assistant
/// `TranscriptItem` so the bubble renders pills for recalled memories
/// and tool calls without inline `[recalled: …]` / `[calling X]`
/// noise polluting the streamed text.
@MainActor
@Observable
final class TranscriptInbox {
    /// Memories `RAGMiddleware.onRecall` surfaced for the in-flight
    /// turn. Cleared at the start of each `send()`.
    var pendingRecall: [String] = []

    func reset() {
        self.pendingRecall = []
    }
}
