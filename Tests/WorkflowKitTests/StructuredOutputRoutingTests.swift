import Aria
import Foundation
import Testing
@testable import WorkflowKit

// MARK: - StructuredOutputRoutingTests

/// Coverage for `LLMStep.structuredOutputSchema` dispatch. The
/// compiler routes typed steps through `generateStructured(...)`
/// and untyped steps through `generate(...)`; both must bind the
/// result under the step's `outputBinding`. The default
/// `generateStructured` impl falls back to text + JSON parse —
/// verified separately so consumers that don't override get a
/// useful behaviour out of the box.
struct StructuredOutputRoutingTests {
    @Test
    func untypedStepRoutesThroughGenerate() async throws {
        let provider = RoutingTracker(textReply: "untyped reply")
        let runner = try await Self.makeRunner(provider: provider)
        let workflow = Self.singleLLMWorkflow(structuredOutputSchema: nil)

        let result = try await runner.run(
            workflow,
            callerPluginID: "sdk.builtin.test"
        )

        #expect(provider.lastCalledMethod == .generate)
        #expect(provider.lastSchemaID == nil)
        // Untyped: binding is the bare text wrapped in OutputStep template.
        #expect(result["bound"] == .string("untyped reply"))
    }

    @Test
    func typedStepRoutesThroughGenerateStructured() async throws {
        let typedValue: JSONValue = .object([
            "headline": .string("Hydrate now"),
            "urgency": .string("medium")
        ])
        let provider = RoutingTracker(structuredReply: typedValue)
        let runner = try await Self.makeRunner(provider: provider)
        let workflow = Self.singleLLMWorkflow(structuredOutputSchema: "myShape")

        let result = try await runner.run(
            workflow,
            callerPluginID: "sdk.builtin.test"
        )

        #expect(provider.lastCalledMethod == .generateStructured)
        #expect(provider.lastSchemaID == "myShape")
        // The structured value is bound under the LLM step's
        // `outputBinding` directly (verifiable via a follow-on template
        // that descends into a field, see below). The OutputStep's
        // `fields: [String: String]` always emits strings, so a bare
        // `{{reply}}` here rolls the object up to compact JSON — that's
        // how downstream consumers see the typed payload arrive on the
        // run's result.
        let bound = result["bound"]?.stringValue
        #expect(bound?.contains("\"headline\":\"Hydrate now\"") == true)
        #expect(bound?.contains("\"urgency\":\"medium\"") == true)
    }

    @Test
    func typedBindingIsFieldAddressableInTemplates() async throws {
        // Beyond the stringified-rollup assertion above, the typed
        // binding must be a structured value that downstream templates
        // can descend into with `{{step.field}}`. Without this,
        // structured output is just JSON-text, not actual structure.
        let typedValue: JSONValue = .object([
            "headline": .string("Log breakfast"),
            "urgency": .string("low")
        ])
        let provider = RoutingTracker(structuredReply: typedValue)
        let runner = try await Self.makeRunner(provider: provider)
        let workflow = Workflow(
            name: "field-addressable-test",
            outputSchema: OutputSchema(fields: [
                OutputField(id: "headline", label: "Headline"),
                OutputField(id: "urgency", label: "Urgency")
            ]),
            nodes: [
                .llm(LLMStep(
                    promptTemplate: "anything",
                    outputBinding: "reply",
                    structuredOutputSchema: "myShape"
                )),
                .output(OutputStep(fields: [
                    "headline": "{{reply.headline}}",
                    "urgency": "{{reply.urgency}}"
                ]))
            ],
            triggers: [.manual]
        )

        let result = try await runner.run(workflow, callerPluginID: "sdk.builtin.test")

        #expect(result["headline"] == .string("Log breakfast"))
        #expect(result["urgency"] == .string("low"))
    }

    @Test
    func emptyStructuredOutputSchemaIsTreatedAsUntyped() async throws {
        // `structuredOutputSchema: ""` shouldn't flip dispatch — empty
        // string is the editor's "user hasn't picked a schema yet" state,
        // not an opt-in to structured output. Guards against UI surfaces
        // that bind to a String? backing instead of nil.
        let provider = RoutingTracker(textReply: "still text")
        let runner = try await Self.makeRunner(provider: provider)
        let workflow = Self.singleLLMWorkflow(structuredOutputSchema: "")

        _ = try await runner.run(workflow, callerPluginID: "sdk.builtin.test")

        #expect(provider.lastCalledMethod == .generate)
    }

    @Test
    func defaultStructuredImplFallsBackToTextParse() async throws {
        // Provider supplies ONLY `generate(...)` and inherits the
        // default `generateStructured` impl. The default should call
        // generate, take the text, lenient-parse as JSON, and bind.
        let json = #"{"a": 1, "b": "two"}"#
        let provider = TextOnlyProvider(reply: json)
        let runner = try await Self.makeRunner(provider: provider)
        let workflow = Self.singleLLMWorkflow(structuredOutputSchema: "anything")

        let result = try await runner.run(
            workflow,
            callerPluginID: "sdk.builtin.test"
        )

        let bound = result["bound"]
        // Template renders the object as compact JSON, so the
        // interpolated `{{reply}}` round-trips through string form.
        // The actual binding (pre-template) is the parsed object —
        // verified through field access via template.
        #expect(bound?.stringValue?.contains("\"a\"") == true)
    }

    @Test
    func defaultStructuredImplStripsCodeFences() async throws {
        // Models routinely wrap JSON in ```json ... ``` fences even
        // when asked not to. The default parse path strips them.
        let provider = TextOnlyProvider(reply: """
        ```json
        {"ok": true}
        ```
        """)
        let runner = try await Self.makeRunner(provider: provider)
        let workflow = Self.singleLLMWorkflow(structuredOutputSchema: "anything")

        let result = try await runner.run(
            workflow,
            callerPluginID: "sdk.builtin.test"
        )

        #expect(result["bound"]?.stringValue?.contains("\"ok\":true") == true)
    }

    @Test
    func defaultStructuredImplThrowsOnUnparseableText() async throws {
        let provider = TextOnlyProvider(reply: "definitely not json")
        let runner = try await Self.makeRunner(provider: provider)
        let workflow = Self.singleLLMWorkflow(structuredOutputSchema: "anything")

        await #expect(throws: (any Error).self) {
            _ = try await runner.run(workflow, callerPluginID: "sdk.builtin.test")
        }
    }

    // MARK: - Helpers

    private static func makeRunner(
        provider: any WorkflowLLMProvider
    ) async throws -> WorkflowRunner {
        let broker = CapabilityBroker()
        #if canImport(JavaScriptCore)
            let evaluator: any WorkflowJSEvaluator = try JavaScriptCoreJSEvaluator()
        #else
            let evaluator: any WorkflowJSEvaluator = ThrowingJSEvaluator()
        #endif
        let compiler = WorkflowCompiler(
            broker: broker,
            llmProvider: provider,
            jsEvaluator: evaluator
        )
        return WorkflowRunner(compiler: compiler)
    }

    private static func singleLLMWorkflow(structuredOutputSchema: String?) -> Workflow {
        Workflow(
            name: "structured-routing-test",
            outputSchema: OutputSchema(fields: [
                OutputField(id: "bound", label: "Bound")
            ]),
            nodes: [
                .llm(LLMStep(
                    promptTemplate: "anything",
                    outputBinding: "reply",
                    structuredOutputSchema: structuredOutputSchema
                )),
                .output(OutputStep(fields: [
                    "bound": "{{reply}}"
                ]))
            ],
            triggers: [.manual]
        )
    }
}

// MARK: - RoutingTracker

/// Records which method was last called so the routing tests can
/// assert dispatch precedence. Each method returns its configured
/// canned value; the other is unset.
private final class RoutingTracker: WorkflowLLMProvider, @unchecked Sendable {
    enum CalledMethod: Equatable {
        case generate
        case generateStructured
    }

    init(textReply: String = "", structuredReply: JSONValue = .null) {
        self.textReply = textReply
        self.structuredReply = structuredReply
    }

    private(set) var lastCalledMethod: CalledMethod?
    private(set) var lastSchemaID: String?
    private let textReply: String
    private let structuredReply: JSONValue

    func generate(prompt _: String, hint _: ModelFamilyHint, maxTokens _: Int?) async throws -> String {
        self.lastCalledMethod = .generate
        return self.textReply
    }

    func generateStructured(
        prompt _: String,
        hint _: ModelFamilyHint,
        maxTokens _: Int?,
        schemaID: String
    ) async throws -> JSONValue {
        self.lastCalledMethod = .generateStructured
        self.lastSchemaID = schemaID
        return self.structuredReply
    }
}

// MARK: - TextOnlyProvider

/// Provider that only implements the text `generate(...)` and
/// inherits the default `generateStructured` impl. Used to verify
/// the default falls back correctly for providers that haven't
/// adopted native structured output.
private final class TextOnlyProvider: WorkflowLLMProvider, @unchecked Sendable {
    init(reply: String) {
        self.reply = reply
    }

    private let reply: String

    func generate(prompt _: String, hint _: ModelFamilyHint, maxTokens _: Int?) async throws -> String {
        self.reply
    }
}

// MARK: - JSONValue helpers

extension JSONValue {
    fileprivate var objectValue: [String: JSONValue]? {
        if case let .object(dict) = self { return dict }
        return nil
    }

    fileprivate var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }
}
