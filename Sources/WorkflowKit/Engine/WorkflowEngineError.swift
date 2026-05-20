import Foundation

// MARK: - WorkflowEngineError

/// Closed set of failure modes the workflow engine surfaces.
/// Callers can switch on the concrete case (e.g. show a "Grant
/// access" sheet when `.capabilityNotGranted` fires, retry on a
/// transient `.providerFailed`).
public enum WorkflowEngineError: Error, Sendable, Equatable {
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
    /// Surface for unexpected runtime errors. Carries the
    /// underlying error's description.
    case underlying(String)
}
