import Aria
import Foundation

// MARK: - WorkflowState

/// The state value `Aria.StateGraph` carries through a workflow
/// run. Two pieces:
///
///   * `bindings` — every node writes to one slot here, keyed by
///     its `outputBinding`. Templates downstream reference it as
///     `{{name}}` / `{{name.field}}`. The runner seeds the
///     workflow's input parameters into `bindings["input"]` as a
///     JSON object before execution starts.
///
///   * `result` — populated only by the terminal `output` node.
///     The runner returns this map as the workflow's result to
///     the caller (AppIntent / library run button / URL scheme
///     x-callback payload).
///
/// `Sendable & Codable` because `StateGraph<State>` requires it
/// — the same conformance powers Aria's checkpointing path so
/// workflow runs can survive an app suspension.
public struct WorkflowState: Sendable, Codable, Equatable {
    // MARK: Lifecycle

    public init(
        bindings: [String: JSONValue] = [:],
        result: [String: JSONValue] = [:]
    ) {
        self.bindings = bindings
        self.result = result
    }

    // MARK: Public

    public var bindings: [String: JSONValue]
    public var result: [String: JSONValue]
}
