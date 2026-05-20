import Foundation

// MARK: - WorkflowLLMProvider

/// Injection seam for the model that drives `LLMStep` nodes.
/// Production wires this to an `Aria.Agent` (slice 15 ships the
/// adapter); tests pass a deterministic stub so the compiler +
/// runner can be exercised without spinning up FoundationModels.
///
/// Returns plain text for now — structured-output decoding
/// (`LLMStep.structuredOutputSchema`) lands in slice 5b as a
/// follow-up; for P0 the compiler treats a structured response
/// as "decode the model's text as JSON and merge fields into
/// the binding."
public protocol WorkflowLLMProvider: Sendable {
    func generate(
        prompt: String,
        hint: ModelFamilyHint,
        maxTokens: Int?
    ) async throws -> String
}

// MARK: - WorkflowJSEvaluator

/// Injection seam for `TransformStep` + `BranchStep` JS bodies.
/// Slice 10 ships the real `JSContext`-backed impl in
/// `AriaToolsJS`; slice 5 ships a stub that throws so the
/// compiler graph wiring still type-checks and the test runner
/// can exercise non-JS workflow paths end-to-end.
public protocol WorkflowJSEvaluator: Sendable {
    /// Evaluate a JS expression against the workflow bindings.
    /// Returns the expression's result as a `JSONValue`. The
    /// compiler is responsible for binding the result into
    /// `WorkflowState.bindings` under the step's `outputBinding`.
    func evaluate(
        expression: String,
        bindings: [String: String]
    ) async throws -> String

    /// Specialised path for branch predicates — the expression
    /// must evaluate to a boolean. Kept separate so the runtime
    /// can fail loud when a workflow author wires a non-bool
    /// condition into a `BranchStep`.
    func evaluateBool(
        expression: String,
        bindings: [String: String]
    ) async throws -> Bool
}

// MARK: - ThrowingJSEvaluator

/// Stub implementation used by P0 test cases that don't exercise
/// JS at all. Slice 10 swaps in the real one.
public struct ThrowingJSEvaluator: WorkflowJSEvaluator {
    // MARK: Lifecycle

    public init() { }

    // MARK: Public

    public func evaluate(expression _: String, bindings _: [String: String]) async throws -> String {
        throw WorkflowEngineError.jsEvaluatorUnavailable
    }

    public func evaluateBool(expression _: String, bindings _: [String: String]) async throws -> Bool {
        throw WorkflowEngineError.jsEvaluatorUnavailable
    }
}
