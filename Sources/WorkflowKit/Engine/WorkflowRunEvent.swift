import Aria
import Foundation

// MARK: - WorkflowRunEvent

/// One observation emitted during a streaming workflow run.
/// `WorkflowRunner.runStreaming(_:input:)` yields these via an
/// `AsyncThrowingStream` so UIs can render per-step status as
/// the engine executes. The set is intentionally small — UI
/// concerns belong outside the runtime, so the event surface
/// only carries the data the renderer needs.
public enum WorkflowRunEvent: Sendable, Equatable {
    /// Engine started executing the named node.
    case stepStarted(nodeID: UUID)
    /// Node finished successfully. `value` is the value that
    /// landed under `outputBinding` (when the step writes one)
    /// — extracted once here so the UI doesn't have to walk
    /// the bindings map itself.
    case stepCompleted(nodeID: UUID, outputBinding: String?, value: JSONValue?)
    /// Node threw. `error` is `localizedDescription` because the
    /// underlying error isn't `Sendable & Equatable` in the
    /// general case — UIs that need typed handling should look
    /// at the stream's terminating throw instead.
    case stepFailed(nodeID: UUID, error: String)
    /// Terminal event on a successful run. Carries the
    /// workflow's `OutputStep` result map.
    case finished(result: [String: JSONValue])
    /// Terminal event on a failed run. The stream also throws
    /// after yielding this; the duplication lets callers that
    /// iterate via `for try await` still see the failure.
    case failed(error: String)
}

// MARK: - WorkflowEventSink

/// Sink the compiler emits step lifecycle events into. The
/// default `runStreaming` path wires up a sink backed by the
/// async stream's continuation; tests can plug in their own.
/// `Sendable` so the engine can hand the sink to a node
/// closure that may hop actors.
public protocol WorkflowEventSink: Sendable {
    func emit(_ event: WorkflowRunEvent) async
}
