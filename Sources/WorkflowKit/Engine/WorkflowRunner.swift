import Aria
import Foundation

// MARK: - WorkflowRunner

/// Public entry point for executing a `Workflow`. Wraps the
/// `WorkflowCompiler` + `CompiledStateGraph.run(...)` pair so
/// callers (AppIntent, library "Run" button, JS plugin
/// `workflow.run(id)`) deal in one Sendable type.
///
/// One instance can run any workflow it has a compiler for —
/// runs are stateless from the runner's perspective; state lives
/// inside the per-run `WorkflowState` carried through the graph.
public struct WorkflowRunner: Sendable {
    // MARK: Lifecycle

    public init(compiler: WorkflowCompiler) {
        self.compiler = compiler
    }

    // MARK: Public

    /// Compile + run a workflow. Returns the populated
    /// `result` map from the workflow's terminal `OutputStep`.
    ///
    /// `input` becomes available to templates as `{{input.field}}`.
    /// Pass the AppIntent / URL-scheme parameters here; the
    /// runner doesn't otherwise mutate the workflow's `inputSchema`.
    public func run(
        _ workflow: Workflow,
        input: [String: JSONValue] = [:],
        callerPluginID: String = "avyra.builtin.host",
        attended: Bool = true
    ) async throws -> [String: JSONValue] {
        let compiled = try self.compiler.compile(
            workflow,
            callerPluginID: callerPluginID,
            attended: attended
        )
        let initial = WorkflowState(bindings: ["input": .object(input)])
        let final = try await compiled.run(initial: initial)
        return final.result
    }

    /// Streaming variant that emits `WorkflowRunEvent` values
    /// as each instrumented step starts / completes / fails,
    /// terminating with `.finished` or `.failed` plus a final
    /// throw on the failure path. The UI run sheet subscribes
    /// to this to render live per-step progress and final
    /// result without polling.
    public func runStreaming(
        _ workflow: Workflow,
        input: [String: JSONValue] = [:],
        callerPluginID: String = "avyra.builtin.host",
        attended: Bool = true
    ) -> AsyncThrowingStream<WorkflowRunEvent, any Error> {
        AsyncThrowingStream { continuation in
            let sink = ContinuationEventSink(continuation: continuation)
            let task = Task {
                do {
                    let compiled = try self.compiler.compile(
                        workflow,
                        callerPluginID: callerPluginID,
                        attended: attended,
                        eventSink: sink
                    )
                    let initial = WorkflowState(bindings: ["input": .object(input)])
                    let final = try await compiled.run(initial: initial)
                    continuation.yield(.finished(result: final.result))
                    continuation.finish()
                } catch {
                    continuation.yield(.failed(error: error.localizedDescription))
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: Private

    private let compiler: WorkflowCompiler
}

// MARK: - ContinuationEventSink

/// `WorkflowEventSink` that forwards events into the
/// `AsyncThrowingStream` continuation `runStreaming` builds.
/// `@unchecked Sendable` because the underlying continuation
/// type isn't marked `Sendable` even though it's safe to use
/// across actors — Apple flags this as a known gap.
private struct ContinuationEventSink: WorkflowEventSink, @unchecked Sendable {
    let continuation: AsyncThrowingStream<WorkflowRunEvent, any Error>.Continuation

    func emit(_ event: WorkflowRunEvent) async {
        self.continuation.yield(event)
    }
}
