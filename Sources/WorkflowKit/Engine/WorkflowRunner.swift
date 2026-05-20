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

    // MARK: Private

    private let compiler: WorkflowCompiler
}
