import Foundation

// MARK: - WorkflowEngineError

/// Closed set of failure modes the workflow engine surfaces.
/// Callers can switch on the concrete case (e.g. show a "Grant
/// access" sheet when `.capabilityNotGranted` fires, retry on a
/// transient `.providerFailed`).
public enum WorkflowEngineError: LocalizedError, Sendable, Equatable {
    /// A `{{path}}` lookup pointed at a missing binding and the
    /// node treats that as fatal. Most paths render the empty
    /// string instead — this only fires for explicit required
    /// substitutions (e.g. a capability arg that can't be `null`).
    case missingBinding(String)
    /// A `CapabilityStep` referenced a capability that hadn't
    /// been registered with the broker. Distinct from the
    /// broker's `unavailable` so the engine layer can surface a
    /// build-time configuration issue.
    case capabilityUnregistered(CapabilityID)
    /// A node returned a value whose shape doesn't match the
    /// step's `outputBinding` expectation.
    case invalidNodeOutput(String)
    /// The configured `WorkflowJSEvaluator` is the stub —
    /// transform / branch nodes can't run. Slice 10 swaps in the
    /// real evaluator; until then any JS step throws this.
    case jsEvaluatorUnavailable
    /// A `PluginToolStep` ran but the compiler was constructed
    /// without a `PluginToolBroker`. Surfaces a configuration
    /// gap rather than a runtime fault.
    case pluginToolBrokerUnavailable
    /// A `PluginToolStep` referenced a plugin id that isn't
    /// currently installed in the broker's view of `JSToolProvider`.
    case unknownPluginTool(String)
    /// A `LoopStep` ran past its declared `maxIterations` without
    /// `condition` going falsy or `breakOn` firing. Surfaces so
    /// the editor can flag a runaway predicate rather than
    /// blocking the workflow forever.
    case loopMaxIterationsExceeded
    /// A `LoopStep` body referenced a node type the loop engine
    /// doesn't lower inline (branch, parallel, nested loop,
    /// output). The associated string names the offending kind
    /// so the run-sheet error banner can tell the user
    /// *which* body step is the problem instead of just
    /// surfacing "error 7".
    case loopBodyContainsUnsupportedNode(String)
    /// Surface for unexpected runtime errors. Carries the
    /// underlying error's description.
    case underlying(String)

    // MARK: Public

    public var errorDescription: String? {
        switch self {
        case let .missingBinding(path):
            "A required binding wasn't set: `\(path)`."
        case let .capabilityUnregistered(capability):
            "The `\(capability.rawValue)` tool isn't registered with the broker."
        case let .invalidNodeOutput(detail):
            "A step produced an invalid output: \(detail)."
        case .jsEvaluatorUnavailable:
            "The JavaScript evaluator isn't available in this build."
        case .pluginToolBrokerUnavailable:
            "Plugin tool steps need a plugin runtime, which wasn't configured."
        case let .unknownPluginTool(pluginID):
            "No installed plugin matches `\(pluginID)`. Install or remove the step."
        case .loopMaxIterationsExceeded:
            "The loop hit its max-iterations cap without the condition going falsy. Tighten the predicate, add a Break early when, or raise Max iterations."
        case let .loopBodyContainsUnsupportedNode(kind):
            "A `\(kind)` step can't live inside a loop body. Remove it from the loop's iteration body."
        case let .underlying(message):
            message
        }
    }
}
