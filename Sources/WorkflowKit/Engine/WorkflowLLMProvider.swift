import Aria
import Foundation

// MARK: - WorkflowLLMProvider

/// Injection seam for the model that drives `LLMStep` nodes.
/// Production wires this to an `Aria.Agent` (slice 15 ships the
/// adapter); tests pass a deterministic stub so the compiler +
/// runner can be exercised without spinning up FoundationModels.
///
/// Two generation entry points:
///   - `generate(...)` returns plain text. Used for `LLMStep`s
///     without a `structuredOutputSchema`. Continues to bind the
///     result as `.string(text)` under the step's `outputBinding`.
///   - `generateStructured(...)` returns a `JSONValue`. The compiler
///     routes here when an `LLMStep` declares a non-empty
///     `structuredOutputSchema`. Bound directly as the structured
///     value under the step's `outputBinding`, so downstream
///     templates can address fields with `{{step.field}}`.
///
/// The default `generateStructured` impl falls back to the text
/// path + lenient JSON parsing (handles markdown code fences the
/// model sometimes emits). Providers with native structured-output
/// support (Apple FoundationModels via `session.respond(to:generating:)`,
/// OpenAI function-calling, etc.) override `generateStructured` to
/// constrain the model with the schema at decode time — that's the
/// big win over prompt-engineered "please emit JSON" instructions.
///
/// The `schemaID` matches `LLMStep.structuredOutputSchema`. WorkflowKit
/// doesn't interpret it — the provider is the only thing that knows
/// what Generable / JSON Schema / OpenAPI shape the id refers to, and
/// maintains its own registry mapping id → schema.
public protocol WorkflowLLMProvider: Sendable {
    /// Declared up-front. Providers may compute this value lazily
    /// but it must be stable for the life of the provider instance.
    /// The compiler's pre-flight pass reads this to validate that
    /// every `LLMStep`'s declared requirements (modalities,
    /// streaming, mid-turn tools, schema id) are satisfied before
    /// any tokens flow — mismatches surface as
    /// `WorkflowEngineError.providerCapabilityMissing(...)` rather
    /// than silent degraded output.
    ///
    /// Conservative default (`WorkflowProviderCapabilities()`) so existing
    /// 0.1.x providers compile unchanged on the 0.2.x upgrade; opt
    /// in to richer capabilities by overriding.
    var capabilities: WorkflowProviderCapabilities { get }

    func generate(
        prompt: String,
        hint: ModelFamilyHint,
        maxTokens: Int?
    ) async throws -> String

    /// Optional warm-up hook fired right before `generate` /
    /// `generateStructured` in the LLM step's executor. On-device
    /// backends (FoundationModels, MLX) override this to load weights
    /// into memory so the first real call doesn't pay cold start;
    /// HTTP-backed server providers inherit the no-op default since
    /// their request is stateless. Errors here are advisory — the
    /// engine logs and continues to the real generate call, where the
    /// underlying failure (if any) surfaces with the user-actionable
    /// diagnostic.
    func prewarm() async throws

    /// Generate a structured (`JSONValue`) response. Called by the
    /// compiler when an `LLMStep` declares a non-empty
    /// `structuredOutputSchema`. Providers that support typed schemas
    /// natively (FoundationModels, OpenAI function-calling, etc.)
    /// override this; the default impl calls `generate(...)` and
    /// lenient-parses the result as JSON.
    func generateStructured(
        prompt: String,
        hint: ModelFamilyHint,
        maxTokens: Int?,
        schemaID: String
    ) async throws -> JSONValue

    /// Streaming variant of `generateStructured`. Yields cumulative
    /// snapshots as the model fills the structured response —
    /// powers typewriter UIs where the user sees fields populate
    /// progressively. Each yield is a complete `JSONValue` matching
    /// the schema so consumers can render at any point.
    ///
    /// Default impl awaits the non-streaming `generateStructured`
    /// and yields exactly one terminal value — a graceful
    /// degradation for providers without native streaming support.
    /// Providers that can stream override this and update
    /// `capabilities.supportsStreamingStructured = true` so the
    /// compiler routes through here when the caller opts into
    /// streaming. Added in 0.2.0.
    func streamStructured(
        prompt: String,
        hint: ModelFamilyHint,
        maxTokens: Int?,
        schemaID: String
    ) -> AsyncThrowingStream<JSONValue, any Error>

    /// Generate a structured response from a multimodal content
    /// list (text + image / audio / file blocks). Routed to by the
    /// runner when an `LLMStep` has non-empty
    /// `attachmentBindings`; the compiler validates ahead of time
    /// that the bound provider advertises every required modality
    /// in `capabilities.supportedModalities`.
    ///
    /// Default impl strips non-text blocks and calls
    /// `generateStructured` — but the compiler pre-flight prevents
    /// this from being a silent loss because mismatched modalities
    /// fail the run before the executor invokes the provider.
    /// Providers with native multimodal support override this; the
    /// default exists so a text-only provider that never sees a
    /// multimodal LLM step in practice doesn't have to implement
    /// the method. Added in 0.2.0.
    func generateMultimodal(
        content: [ContentBlock],
        hint: ModelFamilyHint,
        maxTokens: Int?,
        schemaID: String?
    ) async throws -> JSONValue
}

extension WorkflowLLMProvider {
    /// Conservative default — text-only, no streaming, no mid-turn
    /// tools. Existing 0.1.x providers inherit this on the 0.2.x
    /// upgrade and don't accidentally claim more than they support.
    /// Providers that *do* support richer behaviour override
    /// `capabilities` to advertise it.
    public var capabilities: WorkflowProviderCapabilities {
        .conservative
    }

    /// Default no-op so adopters opt in to warmup only when they
    /// have actual state to prepare. Keeps the OpenAI / Anthropic /
    /// Gemini clients clean (their request shape needs nothing
    /// loaded) and existing fakes / stubs don't have to acknowledge
    /// the hook.
    public func prewarm() async throws { }

    /// Default structured-output impl for providers that don't have
    /// native schema support. Calls the untyped `generate(...)` and
    /// parses the result as JSON, leniently stripping markdown code
    /// fences the model sometimes wraps responses in. Throws
    /// `.underlying` when the text can't be decoded — workflow runs
    /// surface this as a step failure rather than silently producing
    /// an empty binding.
    public func generateStructured(
        prompt: String,
        hint: ModelFamilyHint,
        maxTokens: Int?,
        schemaID _: String
    ) async throws -> JSONValue {
        let text = try await self.generate(
            prompt: prompt,
            hint: hint,
            maxTokens: maxTokens
        )
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = cleaned.data(using: .utf8) else {
            throw WorkflowEngineError.underlying("structured-output text not UTF-8")
        }
        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw WorkflowEngineError.underlying(
                "structured-output text did not parse as JSON: \(error.localizedDescription)"
            )
        }
    }

    /// Default streaming impl: await the non-streaming call and
    /// yield exactly one terminal snapshot. Providers without
    /// native streaming get this for free; consumers see the same
    /// final result they'd get from `generateStructured` plus a
    /// single terminal `.stepPartial` event.
    public func streamStructured(
        prompt: String,
        hint: ModelFamilyHint,
        maxTokens: Int?,
        schemaID: String
    ) -> AsyncThrowingStream<JSONValue, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let value = try await self.generateStructured(
                        prompt: prompt,
                        hint: hint,
                        maxTokens: maxTokens,
                        schemaID: schemaID
                    )
                    continuation.yield(value)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Default multimodal impl: strip non-text blocks, concatenate
    /// the text into a single prompt, and dispatch to the structured
    /// or untyped path based on `schemaID`. Safe because the compiler
    /// pre-flight rejects multimodal steps bound to providers that
    /// don't advertise the right modality — by the time the runner
    /// reaches this default it's guaranteed all blocks are text.
    public func generateMultimodal(
        content: [ContentBlock],
        hint: ModelFamilyHint,
        maxTokens: Int?,
        schemaID: String?
    ) async throws -> JSONValue {
        let text = content.compactMap { block -> String? in
            if case let .text(value) = block {
                return value
            }
            return nil
        }.joined(separator: "\n\n")
        if let schemaID, !schemaID.isEmpty {
            return try await self.generateStructured(
                prompt: text,
                hint: hint,
                maxTokens: maxTokens,
                schemaID: schemaID
            )
        }
        let plain = try await self.generate(prompt: text, hint: hint, maxTokens: maxTokens)
        return .string(plain)
    }
}

// MARK: - SubAgentExecutor

/// Host-supplied executor that runs an `AgentDefinition` (resolved
/// by `agentDefinitionID`) and returns the final answer. WorkflowKit
/// stays dependency-free of AgentKit — the host wires
/// `AgentRuntime` (or any equivalent) through this protocol when it
/// wants to enable `SubAgentStep` nodes in its workflows.
///
/// `final.text` is always present; `final.structured` is set when
/// the agent definition has a typed answer schema (AgentKit 0.2.x+
/// — until then, leave `nil`).
public protocol SubAgentExecutor: Sendable {
    func run(
        agentDefinitionID: UUID,
        inputs: [String: JSONValue],
        maxSteps: Int?,
        attended: Bool
    ) async throws -> SubAgentResult
}

// MARK: - SubAgentResult

public struct SubAgentResult: Sendable, Equatable {
    // MARK: Lifecycle

    public init(text: String, structured: JSONValue? = nil) {
        self.text = text
        self.structured = structured
    }

    // MARK: Public

    public let text: String
    public let structured: JSONValue?

    /// Pack into the `JSONValue` shape the workflow binds under
    /// `SubAgentStep.outputBinding` — `{"text": "...",
    /// "structured": ...}`. Always emits both keys so downstream
    /// templates can safely reference either; `structured` is
    /// `.null` when absent.
    public var asBinding: JSONValue {
        .object([
            "text": .string(self.text),
            "structured": self.structured ?? .null
        ])
    }
}

// MARK: - WorkflowJSEvaluator

/// Injection seam for `TransformStep` + `BranchStep` JS bodies.
/// Slice 10 ships the real `JSContext`-backed impl in
/// `AriaToolsJS`; slice 5 ships a stub that throws so the
/// compiler graph wiring still type-checks and the test runner
/// can exercise non-JS workflow paths end-to-end.
public protocol WorkflowJSEvaluator: Sendable {
    /// Evaluate a JS expression against the workflow bindings.
    /// Bindings arrive as their native `JSONValue` shape; the
    /// implementation is responsible for translating to a JS
    /// object the expression can reference (typically as `b`).
    /// Returns the expression's result as a `JSONValue` so the
    /// compiler can bind it directly into
    /// `WorkflowState.bindings` under the step's `outputBinding`.
    func evaluate(
        expression: String,
        bindings: [String: JSONValue]
    ) async throws -> JSONValue

    /// Specialised path for branch predicates — the expression
    /// must evaluate to a boolean. Kept separate so the runtime
    /// can fail loud when a workflow author wires a non-bool
    /// condition into a `BranchStep`.
    func evaluateBool(
        expression: String,
        bindings: [String: JSONValue]
    ) async throws -> Bool
}

// MARK: - ThrowingJSEvaluator

/// Stub implementation used by P0 test cases that don't exercise
/// JS at all. Slice 10 swaps in the real one.
public struct ThrowingJSEvaluator: WorkflowJSEvaluator {
    // MARK: Lifecycle

    public init() { }

    // MARK: Public

    public func evaluate(
        expression _: String,
        bindings _: [String: JSONValue]
    ) async throws -> JSONValue {
        throw WorkflowEngineError.jsEvaluatorUnavailable
    }

    public func evaluateBool(
        expression _: String,
        bindings _: [String: JSONValue]
    ) async throws -> Bool {
        throw WorkflowEngineError.jsEvaluatorUnavailable
    }
}
